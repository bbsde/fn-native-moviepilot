# fn-native-moviepilot

A [MoviePilot](https://github.com/jxxghp/MoviePilot) application packaged for
飞牛 fnOS using the Native framework. It runs as a native process on fnOS,
providing automated media management: resource search, subscriptions,
organization, scraping, transfer and notifications.

## App Info

| Item | Value |
| --- | --- |
| appname | `moviepilot` |
| Mode | Native process |
| Platform | x86 |
| Service port | `3000` (frontend; backend API on 3001) |
| Data shares | `moviepilot/config`, `moviepilot/data` |
| Run as | `moviepilot` (package) |
| Depends on | `nodejs_v24` (auto-installed) |

The admin account is set during the install wizard. If installed without the
wizard, the default is `admin` / `moviepilot123` — change it after first login.

## How It Works

MoviePilot v2 ships its own local (non-Docker) install & runtime system
(`scripts/local_setup.py` + `moviepilot` CLI). This app is a **thin wrapper**
around it:

- **Install**: `install_callback` clones the v2 branch via git, then runs the
  upstream `moviepilot setup` to build the venv, install Python deps, the
  CloakBrowser kernel, frontend and resources
- **Runtime**: `cmd/main` delegates to the `moviepilot` CLI for process
  management (backend Python/FastAPI on :3001 + frontend Node/express on :3000)
- **Updates**: git-based deployment supports in-app updates via the MoviePilot
  web UI or `moviepilot update`

## Directory Layout

```
fn-native-moviepilot/
├── manifest              # app metadata
├── config/
│   ├── privilege         # run-as: package
│   └── resource          # data-share declarations
├── cmd/                  # lifecycle scripts
│   ├── main              # start / stop / status
│   ├── install_callback  # install: git clone + setup
│   ├── upgrade_callback  # upgrade: git pull + setup
│   ├── uninstall_callback
│   └── *_init / config_*
├── app/
│   ├── ui/config         # desktop entry (port-service mode)
│   └── bin/              # bundled scripts
│       ├── curl-github-mirror      # curl wrapper, routes GitHub via mirror
│       └── github-mirror-probe     # multi-mirror auto-detection
├── wizard/install        # install wizard (set admin account/password)
├── ICON.PNG / ICON_256.PNG
└── README.md
```

## Mirror Acceleration

The install uses China-friendly mirrors throughout (without modifying
MoviePilot source):

| Download | Mirror |
| --- | --- |
| Python deps | Tsinghua PyPI |
| npm deps | npmmirror |
| GitHub (source/frontend/resources) | Multi-mirror auto-detect (v4.gh-proxy.org etc.), falls back to direct |
| CloakBrowser kernel | GitHub Release (via mirror), falls back to cloakbrowser.dev |

## Build & Install

```bash
# Build the .fpk (kernel is no longer bundled; downloaded from GitHub Release on install)
fnpack build

# Install on a fnOS device
appcenter-cli install-fpk moviepilot.fpk
```

## Links

- MoviePilot upstream: <https://github.com/jxxghp/MoviePilot>
- fnOS app development: <https://help.fnnas.com>
