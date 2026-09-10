# HR System

A standalone HTML, CSS, and JavaScript application. No dependency installation or build step is required.

## Run locally

From this directory, run:

```sh
python3 -m http.server 8000 --bind 127.0.0.1
```

Open http://127.0.0.1:8000 in your browser. Stop the server with Ctrl+C.

`index.html` is the default entry point. `hr-system.html` is the alternate HTML file supplied with the project. Google Fonts requires an internet connection; system fonts are used as fallbacks.

## Design prototype

Open http://127.0.0.1:8000/prototype/ for the new company, permissions, and hiring workflow prototype. It uses 40 synthetic employees across four sample companies and saves demo changes in this browser's local storage. Reset demo restores the starting data.

The prototype runs entirely locally with no dependencies or external fonts. It does not enforce user permissions, connect external accounts, send messages, or publish jobs outside the browser. The original application remains at the root URL.

See [the design walkthrough](docs/design-round-01.md), [the system blueprint](docs/hr-system-blueprint.md), and [the core HR plan](docs/hr-product-plan.md).
