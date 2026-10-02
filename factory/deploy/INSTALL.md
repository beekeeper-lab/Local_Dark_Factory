# Installing the line as a service (Phase 4, task 7)

Run on Forge, one line at a time. Every line needs sudo, which is why the owner
runs them rather than the line or Claude.

## 1. The factory user, its directories, rootless podman

```
sudo useradd --system --create-home --home-dir /var/lib/darkfactory --shell /usr/sbin/nologin factory
sudo usermod --add-subuids 300000-365535 --add-subgids 300000-365535 factory
sudo mkdir -p /etc/darkfactory /opt/darkfactory /var/lib/darkfactory/repos /var/lib/darkfactory/containers/storage
sudo chown -R factory:factory /var/lib/darkfactory
```

## 2. The line's code, read-only to the service

```
sudo git clone https://github.com/beekeeper-lab/Local_Dark_Factory.git /opt/darkfactory
sudo python3 -m venv /opt/darkfactory/.venv
sudo /opt/darkfactory/.venv/bin/pip install -q jsonschema pyyaml referencing
```

## 3. Configuration: podman storage, and a GitHub token with no other key

```
sudo cp /opt/darkfactory/factory/deploy/storage.conf /etc/darkfactory/storage.conf
sudo install -m 0600 -o root -g root /opt/darkfactory/factory/deploy/env.example /etc/darkfactory/env
sudo nano /etc/darkfactory/env
```

Put the factory account's token after `GH_TOKEN=`. Nothing else goes in that file.

## 4. A target repository, cloned as the factory user

```
sudo -u factory git clone https://github.com/beekeeper-lab/seating-planner-py.git /var/lib/darkfactory/repos/seating-planner-py
```

## 4b. The images, copied into the factory user's own podman storage

Rootless podman keeps images per user, so the worker and gate images built under
your account are not visible to `factory`. Copy them, by the names the lock files pin:

```
podman save localhost/factory-worker-pi:20260923 | sudo -u factory env CONTAINERS_STORAGE_CONF=/etc/darkfactory/storage.conf XDG_RUNTIME_DIR=/run/darkfactory podman load
podman save ghcr.io/beekeeper-lab/factory-gate-python:20260914 | sudo -u factory env CONTAINERS_STORAGE_CONF=/etc/darkfactory/storage.conf XDG_RUNTIME_DIR=/run/darkfactory podman load
```

(Check the tags against `factory/worker.lock.yaml` and the target's
`factory/gates.lock.yaml` first; the worker image pins a digest.)

## 4c. Git pushes through the token

```
sudo -u factory env GH_TOKEN="$(sudo sed -n 's/^GH_TOKEN=//p' /etc/darkfactory/env)" gh auth setup-git
```

## 4d. Pi's model list, and nothing else of yours

The worker runs Pi, which reads its models from `~/.pi/agent`. Copy only the model
list and settings. Your `auth.json` holds credentials and must not come across.

```
sudo install -d -o factory -g factory /var/lib/darkfactory/.pi/agent
sudo install -o factory -g factory -m 0644 ~/.pi/agent/models.json ~/.pi/agent/settings.json /var/lib/darkfactory/.pi/agent/
```

## 5. The unit

```
sudo cp /opt/darkfactory/factory/deploy/darkfactory@.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo /opt/darkfactory/factory/deploy/check-unit.sh seating-planner-py
sudo systemctl enable --now darkfactory@seating-planner-py
```

`check-unit.sh` runs before the unit is started and refuses if anything is off.
Stopping the unit (`sudo systemctl stop darkfactory@seating-planner-py`) is a
drain: every run finishes its current step and the next start resumes it.
