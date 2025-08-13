from googleapiclient import discovery
from google.auth import default
import time
import sys  # for CLI mode if you use it

#----------------------------------
# Constants: List of APIs to Enable
#----------------------------------

REQUIRED_APIS = [
    "certificatemanager.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "serviceusage.googleapis.com",
    "cloudbilling.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudkms.googleapis.com",
    "orgpolicy.googleapis.com",
    "servicenetworking.googleapis.com",
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
    "sqladmin.googleapis.com",
    "aiplatform.googleapis.com",
    "bigquery.googleapis.com",
    "cloudbuild.googleapis.com",
    "pubsub.googleapis.com",
    "spanner.googleapis.com",
    "secretmanager.googleapis.com",
    "vpcaccess.googleapis.com",
    "networkservices.googleapis.com",
    "eventarc.googleapis.com",
    "notebooks.googleapis.com"
]

# ------------------------------
# Function: Check + Enable APIs
# ------------------------------

def enable_apis(project_id: str, api_list: list = None):
    """
    Enables the given list of APIs for the specified GCP project.
    If an API is already enabled, it is skipped.
    """
    api_list = api_list or REQUIRED_APIS   # <-- default so orchestrator can omit it
    credentials, _ = default()
    service = discovery.build('serviceusage', 'v1', credentials=credentials)

    for api in api_list:
        api_name = f'projects/{project_id}/services/{api}'
        try:
            # Check if already enabled
            response = service.services().get(name=api_name).execute()
            if response.get("state") == "ENABLED":
                print(f"Already enabled: {api}")
                continue

            print(f"Enabling API: {api}")
            op = service.services().enable(name=api_name).execute()

            # Wait for operation to complete (best-effort)
            if "name" in op:
                op_name = op["name"]
                while True:
                    op_result = service.operations().get(name=op_name).execute()
                    if op_result.get("done"):
                        print(f"Successfully enabled: {api}")
                        break
                    time.sleep(2)

        except Exception as e:
            print(f"Error with enabling API {api}: {e}")

def main(project_id: str, api_list: list = None):
    # thin wrapper so orchestrator can call func="main"
    return enable_apis(project_id, api_list)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python -m scripts.gcp.enable_prj_apis <project_id>")
        sys.exit(1)
    main(sys.argv[1])
