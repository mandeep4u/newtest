import json
import os
import traceback

CHECKPOINT_FILE = "orchestration_state.json"

STEPS = [
    ("create_project", "scripts.list_enabled_apis"),
    ("enable_apis", "scripts.list_enabled_apis"),
    ("configure_network", "scripts.list_projects"),
    ("deploy_app", "scripts.list_storage_buckets"),
]

def load_checkpoint():
    if os.path.exists(CHECKPOINT_FILE):
        with open(CHECKPOINT_FILE, "r") as f:
            return json.load(f)
    return {}

def save_checkpoint(state):
    with open(CHECKPOINT_FILE, "w") as f:
        json.dump(state, f, indent=2)

def run_step(step_name, module_path):
    module = __import__(module_path, fromlist=[""])
    func = getattr(module, "main")
    func()

def main(project_name, env_type):
    state = load_checkpoint()
    if project_name not in state:
        state[project_name] = {"completed": []}


    for step_name, module_path in STEPS:
        if step_name in state[project_name]["completed"]:
            print(f"Skipping {step_name} for {project_name} (already done)")
            continue

        try:
            print(f"🚀 Running {step_name} for {project_name}...")
            run_step(step_name, module_path)
            state[project_name]["completed"].append(step_name)
            save_checkpoint(state)
        except Exception as e:
            print(f"Error in {step_name} for {project_name}: {e}")
            traceback.print_exc()
            print("Stopping execution. You can re-run to resume.")
            break

if __name__ == "__main__":
    # Pass project_name dynamically (e.g., from env var or argument)
    main(project_name="test2-b-468317", env_type="dev")
