# orchestrator.py
import json
import os
import traceback
import importlib

CHECKPOINT_FILE = "orchestration_state.json"

STEPS = [
    {
      "name": "create_project",
      "module": "scripts.create_project",
      "func": "run_project_creation",
      "args": {"region": "us", "env": "uat", "appPostfix": "aiagent-nav", "lob": "adv"}
    },
    {
      "name": "enable_apis",
      "module": "scripts.enable_apis",
      "func": "main",
      "args": {"project_id": "prj-us-adv-aiagnt-nav-uat"}
    },
    {
      "name": "configure_network",
      "module": "scripts.configure_network",
      "func": "main",
      "args": {"project_id": "prj-us-adv-aiagnt-nav-uat", "env_type": "uat", "vpc_name": "uat-shared-vpc"}
    },
    {
      "name": "deploy_app",
      "module": "scripts.deploy_app",
      "func": "main",
      "args": {"project_id": "prj-us-adv-aiagnt-nav-uat"}
    },
]

def load_checkpoint():
    if os.path.exists(CHECKPOINT_FILE):
        with open(CHECKPOINT_FILE, "r") as f:
            return json.load(f)
    return {"completed": []}

def save_checkpoint(state):
    with open(CHECKPOINT_FILE, "w") as f:
        json.dump(state, f, indent=2)

def run_step(module_path: str, func_name: str, args: dict):
    mod = importlib.import_module(module_path)
    fn = getattr(mod, func_name or "main")
    return fn(**(args or {}))

def main():
    state = load_checkpoint()

    for s in STEPS:
        step_name = s["name"]
        if step_name in state["completed"]:
            print(f"Skipping {step_name} (already done)")
            continue

        try:
            print(f"Running {step_name} …")
            run_step(s["module"], s.get("func", "main"), s.get("args", {}))
            state["completed"].append(step_name)
            save_checkpoint(state)
        except Exception as e:
            print(f"Error in {step_name}: {e}")
            traceback.print_exc()
            print("Stopping execution. Re-run to resume.")
            break

if __name__ == "__main__":
    main()
