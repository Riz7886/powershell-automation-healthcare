from flask import Flask, request, jsonify
import requests
import os
import json
from datetime import datetime

app = Flask(__name__)

PAGERDUTY_ROUTING_KEY = os.getenv('PAGERDUTY_ROUTING_KEY')
PAGERDUTY_URL = 'https://events.pagerduty.com/v2/enqueue'

TARGET_VMS = ['MOVITAUTO', 'MOVEITXFR', 'PYXSFTP']

@app.route('/webhook', methods=['POST'])
def webhook():
    try:
        data = request.json
        
        hostname = data.get('hostname', '').upper()
        
        if not any(vm in hostname for vm in TARGET_VMS):
            return jsonify({'status': 'ignored', 'reason': 'VM not in target list'}), 200
        
        alert_type = data.get('alert_type', 'error')
        title = data.get('title', 'Datadog Alert')
        body = data.get('body', 'No description provided')
        
        severity_map = {
            'error': 'error',
            'warning': 'warning',
            'info': 'info'
        }
        
        pagerduty_payload = {
            'routing_key': PAGERDUTY_ROUTING_KEY,
            'event_action': 'trigger',
            'payload': {
                'summary': f'{hostname}: {title}',
                'source': hostname,
                'severity': severity_map.get(alert_type, 'error'),
                'timestamp': datetime.utcnow().isoformat(),
                'custom_details': {
                    'body': body,
                    'alert_type': alert_type,
                    'hostname': hostname
                }
            }
        }
        
        response = requests.post(
            PAGERDUTY_URL,
            json=pagerduty_payload,
            headers={'Content-Type': 'application/json'},
            timeout=10
        )
        
        if response.status_code == 202:
            return jsonify({'status': 'success', 'pagerduty_response': response.json()}), 200
        else:
            return jsonify({'status': 'failed', 'error': response.text}), 500
            
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500

@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'healthy', 'timestamp': datetime.utcnow().isoformat()}), 200

if __name__ == '__main__':
    port = int(os.getenv('PORT', 5000))
    app.run(host='0.0.0.0', port=port)