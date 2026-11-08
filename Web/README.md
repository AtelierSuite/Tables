# Tables for the web

The offline, installable web version of Tables: the Swift spreadsheet engine compiled to WebAssembly, with a web UI built on the Tables design system.

- [PLAN.md](PLAN.md): the porting plan and its phases.
- [design/](design/): the design system. Run `npm run design` and open the printed address to see every component. Rules are in `design/DESIGN.md`.

Check the design rules:

```sh
npm run lint:design   # or: node design/lint.mjs
npm run design        # serves the specimen at http://localhost:8000/design/
```
