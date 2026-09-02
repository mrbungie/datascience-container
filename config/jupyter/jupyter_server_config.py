import os

c = get_config()  # noqa: F821

c.ServerApp.ip = "127.0.0.1"
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.root_dir = os.environ.get("WORKSPACE", "/workspace")
c.ServerApp.allow_root = True
c.ServerApp.allow_remote_access = True

# nginx terminates the connection in front of this process, so it's fine to
# not require Jupyter's own HTTPS here.
c.ServerApp.disable_check_xsrf = False

# Token is generated/injected by scripts/start.sh (env JUPYTER_TOKEN or
# an auto-generated one persisted to /workspace/run/jupyter.token).
c.ServerApp.token = os.environ.get("JUPYTER_TOKEN", "")

# Add further customization below — this file is copied to
# /workspace/config/jupyter/ on first boot and lives on the persistent
# volume from then on, so edits survive restarts.
