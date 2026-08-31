# external — delegate to a launcher that owns its own containers.
#
# For a model llm-ctl cannot start with one `run`: a multi-node deployment, a
# compose stack, a vendor recipe. llm-ctl calls LAUNCHER, then watches
# CONTAINER_NAME on this model's port; stop calls STOPPER. The conf needs:
#
#   BACKEND=external
#   LAUNCHER="/path/to/start.sh"     exits 0 once it has handed off
#   STOPPER="/path/to/stop.sh"       tears down every node it started
#   CONTAINER_NAME="the-head-container"
#   MODEL_PORT=8888
#   LOGGER="/path/to/logs.sh"        optional; else logs of CONTAINER_NAME
#   NODES=2                          optional; shown by status
backend_describe() { printf 'delegate to an external LAUNCHER/STOPPER'; }
