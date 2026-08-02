# Development-only host compatibility for Ubuntu AppArmor installations that
# deny BitBake's unprivileged network namespace. Release builds refuse the
# enabling CLI option in scripts/build.sh.

python () {
    if d.getVar("COSMOPOD_ALLOW_UNCONFINED_TASK_NETWORK") != "true":
        return
    tasks = d.getVar("__BBTASKS") or []
    if isinstance(tasks, str):
        tasks = tasks.split()
    for task in tasks:
        d.setVarFlag(task, "network", "1")
}
