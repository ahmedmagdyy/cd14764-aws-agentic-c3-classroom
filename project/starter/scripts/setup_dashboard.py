"""Create or update the NovaMart customer support observability dashboard.

Usage (from project/starter):
  python scripts/setup_dashboard.py
  python scripts/setup_dashboard.py --dry-run
  python scripts/setup_dashboard.py --name NovaMart-Agents --delete

Reads .env through config and uses existing agent logs and Bedrock metrics.
Requires CloudWatch PutDashboard or DeleteDashboards permissions; --dry-run
only prints JSON but config may need AWS access to resolve stack exports.
Exits 0 on success, 1 on AWS failures, or 2 for invalid arguments/configuration.
"""

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import quote

import boto3
from botocore.exceptions import BotoCoreError, ClientError

STARTER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(STARTER_DIR / 'src'))
sys.path.insert(0, str(STARTER_DIR))
import config

# ─────────────────────────────────────────────────────
# DASHBOARD BODY
# ─────────────────────────────────────────────────────

def dashboard_body(region, log_group, guardrail_arn, guardrail_version) -> dict:
    """Build a dashboard from supplied values without config or AWS access."""
    guardrail_id = guardrail_arn.rsplit('/', 1)[-1] if guardrail_arn else ''
    guardrail = (f'`{guardrail_id}` / `{guardrail_version}`' if guardrail_arn
                 else 'not configured (guardrail-specific metrics omitted)')
    widgets = [{
        'type': 'text', 'x': 0, 'y': 0, 'width': 24, 'height': 4,
        'properties': {'markdown': (
            '# NovaMart Agents\n'
            'Customer requests, agent invocation counts and response latency, '
            'parallel policy retrieval, and guardrail trigger frequency.\n\n'
            f'**Log group:** `{log_group}`  \n'
            f'**Guardrail ID / version:** {guardrail}\n\n'
            'Policy-type interventions include all guardrails and operations '
            'in this region. Agent latency measures completed route tools.'
        )},
    }]

    def add_widget(widget_type, properties):
        index = len(widgets) - 1
        widgets.append({
            'type': widget_type, 'x': (index % 2) * 12,
            'y': 4 + (index // 2) * 6, 'width': 12, 'height': 6,
            'properties': {'region': region, **properties},
        })

    source = "SOURCE '" + log_group.replace('\\', '\\\\').replace("'", "\\'") + "' | "
    agent_parse = (
        r'parse @message /tool done\s+route_to_(?<agent>\w+)_agent '
        r'\((?<secs>[\d.]+)s\)/ | filter ispresent(agent) | '
    )

    add_widget('log', {
        'title': 'Customer requests', 'view': 'timeSeries',
        'query': source + r'filter @message like /trace \S+ started \|/ '
                 '| stats count(*) as requests by bin(5m)',
    })
    add_widget('log', {
        'title': 'Average and p90 latency per agent (s)', 'view': 'table',
        'query': source + agent_parse
                 + 'stats count(*) as calls, avg(secs) as avg_seconds, '
                   'pct(secs, 90) as p90_seconds by agent | sort avg_seconds desc',
    })
    add_widget('log', {
        'title': 'Average latency per agent over time (s)', 'view': 'timeSeries',
        'query': source + agent_parse + 'stats avg(secs) by bin(5m), agent',
    })
    add_widget('log', {
        'title': 'Agent calls over time', 'view': 'timeSeries',
        'query': source + agent_parse + 'stats count(*) by bin(5m), agent',
    })
    add_widget('log', {
        'title': 'Parallel policy retrieval latency (s)', 'view': 'timeSeries',
        'query': source
                 + r'parse @message /tool done\s+search_all_policies \((?<secs>[\d.]+)s\)/ '
                   '| filter ispresent(secs) '
                   '| stats avg(secs) as avg_seconds, max(secs) as max_seconds by bin(5m)',
    })

    dimensions = ['GuardrailArn', guardrail_arn, 'GuardrailVersion', guardrail_version]
    if guardrail_arn:
        add_widget('metric', {
            'title': 'Guardrail invocations vs interventions', 'view': 'timeSeries',
            'stat': 'Sum', 'period': 300,
            'metrics': [
                ['AWS/Bedrock/Guardrails', 'Invocations', *dimensions],
                ['AWS/Bedrock/Guardrails', 'InvocationsIntervened', *dimensions],
            ],
        })

    add_widget('metric', {
        'title': 'Guardrail interventions by policy type', 'view': 'timeSeries',
        'stat': 'Sum', 'period': 300, 'stacked': True,
        'metrics': [[{
            'expression': "SEARCH('{AWS/Bedrock/Guardrails,GuardrailContentSource,"
                          "GuardrailPolicyType,Operation} MetricName=\"InvocationsIntervened\"', 'Sum', 300)",
            'id': 'e1', 'label': 'Policy interventions',
        }]],
    })

    if guardrail_arn:
        add_widget('metric', {
            'title': 'Guardrail latency (ms)', 'view': 'timeSeries',
            'stat': 'Average', 'period': 300,
            'metrics': [['AWS/Bedrock/Guardrails', 'InvocationLatency', *dimensions]],
        })

    return {'start': '-PT3H', 'periodOverride': 'inherit', 'widgets': widgets}

# ─────────────────────────────────────────────────────
# COMMAND LINE
# ─────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='Print dashboard JSON without changes')
    mode.add_argument('--delete', action='store_true', help='Delete the dashboard if it exists')
    parser.add_argument('--name', default='NovaMart-Agents', help='Dashboard name (default: NovaMart-Agents)')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,255}', args.name):
        parser.error('--name must contain 1–255 letters, digits, hyphens, or underscores.')

    try:
        region = config.AWS_REGION
        if not region:
            parser.error('Set AWS_REGION in config.')
        if not args.delete:
            log_group = config.AGENT_LOG_GROUP
            if not log_group:
                parser.error('Set AGENT_LOG_GROUP in config.')
            guardrail_id = config.GUARDRAIL_ID.strip()
            guardrail_arn = ''
            guardrail_version = ''
            if guardrail_id:
                guardrail_version = config.GUARDRAIL_VERSION.strip()
                account_id = config.ACCOUNT_ID
                if not guardrail_version or not account_id:
                    parser.error('GUARDRAIL_VERSION and ACCOUNT_ID are required when GUARDRAIL_ID is set.')
                guardrail_arn = f'arn:aws:bedrock:{region}:{account_id}:guardrail/{guardrail_id}'
            else:
                print('  Note: GUARDRAIL_ID is empty; omitting guardrail-specific widgets '
                      'and keeping the regional policy SEARCH widget.', file=sys.stderr)
            body = json.dumps(dashboard_body(region, log_group, guardrail_arn,
                                             guardrail_version), indent=2)
    except config.ConfigError as exc:
        print(f'  Dashboard configuration failed: {exc}', file=sys.stderr)
        return 2
    except (BotoCoreError, ClientError) as exc:
        print(f'  AWS configuration lookup failed: {exc}', file=sys.stderr)
        return 1

    if args.dry_run:
        print(body)
        return 0

    try:
        cloudwatch = boto3.client('cloudwatch', region_name=region)
    except (BotoCoreError, ClientError) as exc:
        print(f'  CloudWatch client setup failed: {exc}', file=sys.stderr)
        return 1

    if args.delete:
        try:
            cloudwatch.delete_dashboards(DashboardNames=[args.name])
        except ClientError as exc:
            if exc.response.get('Error', {}).get('Code') in ('ResourceNotFound', 'ResourceNotFoundException'):
                print(f'  Dashboard {args.name} is already deleted.')
                return 0
            print(f'  Dashboard deletion failed: {exc}', file=sys.stderr)
            return 1
        except BotoCoreError as exc:
            print(f'  Dashboard deletion failed: {exc}', file=sys.stderr)
            return 1
        print(f'  Deleted dashboard {args.name}.')
        return 0

    try:
        response = cloudwatch.put_dashboard(DashboardName=args.name, DashboardBody=body)
    except (BotoCoreError, ClientError) as exc:
        print(f'  Dashboard creation/update failed: {exc}', file=sys.stderr)
        return 1
    print(f'  Created or updated dashboard {args.name}.')
    for message in response.get('DashboardValidationMessages', []):
        print(f"  Validation {message.get('DataPath', '')}: {message.get('Message', '')}")
    print(f'  https://{region}.console.aws.amazon.com/cloudwatch/home?region={region}'
          f'#dashboards/dashboard/{quote(args.name, safe="")}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
