Build (or update) **${PRODUCT}**, the frontend of the ${PLATFORM} platform, from the project that is already prepared at `/workspace/apps/peyda`. Source stamp of that project: `${STAMP}`.

Do this, in order:

1. `appui_create` with: title "${PRODUCT}", ui "elpian", audience "platform", kind "app", and this brief: "Peyda: a search engine for the Iranian web. A minimal Google-like first page; a results page with results from many Iranian services side by side; and, behind the Agentic search switch, a chat page where the Peyda Analyst agent runs the extract → search → review loop and talks with the person. The complete source is prepared in /workspace/apps/peyda: use it as is." If an app titled "${PRODUCT}" already exists in this space, pass its `dir` so it is **updated**, not duplicated.
2. Copy the prepared source into the app's project directory, replacing what is there, but **keeping** the platform's own files (`JOB.json`, `APPS.json`, `BRIEF.md`, `CHANGES.md`, `vendor/`, `.decillion/`, `READY.json` if it exists): `rsync -a --delete --exclude JOB.json --exclude APPS.json --exclude BRIEF.md --exclude CHANGES.md --exclude vendor --exclude .decillion --exclude READY.json /workspace/apps/peyda/ <project dir>/`.
3. Read `APPS.json` in the project: it must list the agent **Peyda Analyst**. If it does not, stop and say so.
4. The Python environment is already installed at `/workspace/.venvs/peyda` (with the model and the iran-mcp servers). Do not install anything else. The server starts with `sh start.sh` and listens on the port in `JOB.json` (set `PORT` to it).
5. Build the bundle: `node vendor/decillion-elpian/bundle.mjs .`. Run the validator on the program and fix anything it reports: `node vendor/decillion-elpian/validate.mjs --program elpian/app.js --server http://127.0.0.1:$PORT --strict`.
6. Run the server's tests (`/workspace/.venvs/peyda/bin/python -m pytest -q`) and the scenarios (`node vendor/decillion-elpian/drive.mjs run elpian/e2e --server http://127.0.0.1:$PORT`). Both must pass.
7. Write `READY.json`: `{"ok": true, "tested": true, "title": "${PRODUCT}", "port": <JOB.json port>, "start": "PORT=<port> sh start.sh", "dir": ".", "summary": "A search engine for the Iranian web with an agentic chat", "ui": "elpian", "elpian": "elpian/app.js"}`.
8. Write the source stamp into the project so a later run can tell whether it is current: `printf %s "${STAMP}" > <project dir>/.peyda_source`.
9. `appui_publish` the project. If it reports problems, fix them and publish again. Do **not** call `platform_publish`: the installer publishes the platform's frontend itself.

Reply with one line: the project directory and what `appui_publish` answered.
