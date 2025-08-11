from googleapiclient import discovery
from google.auth import default

PROJECT_ID = "test1-a-468317"  # replace this with your GCP project ID

def main():
    creds, _ = default()
    service = discovery.build('serviceusage', 'v1', credentials=creds)

    name = f"projects/test2-b-468317"
    request = service.services().list(parent=name, filter='state:ENABLED')
    response = request.execute()

    print(f"Enabled APIs in project test1-a-468317:")
    for svc in response.get('services', []):
        print(f"- {svc['config']['name']}")

if __name__ == "__main__":
    main()
