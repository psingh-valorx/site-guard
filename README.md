# Site Guard

A Claude Code plugin that checks whether your work on a Webflow dev site broke anything. Run one command after publishing, and it checks forms, key flows, SEO and images against production, then gives you a PDF report.

```
/site-guard:check
```

Use `/site-guard:check --full` before a production publish. It checks all of the session's work and runs the wider non-submitting checks.

## Install

Run these in a normal terminal, such as PowerShell, then start a new Claude Code session:

```
claude plugin marketplace add psingh-valorx/site-guard
claude plugin install site-guard@valorx-tools
```

You need Claude Code's `claude` command on your laptop. Inside a terminal Claude Code session you can use `/plugin` instead, but the desktop app's Code tab and the VS Code panel don't have that panel.

**Desktop app:** use a local session on Windows. Once the marketplace is added, you can also manage the plugin from **+** > **Plugins** next to the prompt box. It doesn't work in WSL or cloud sessions, and it doesn't appear in Cowork.

## Team setup in one file

To set up your team, run this once on your own laptop, after your two private files are in place:

```
powershell -ExecutionPolicy Bypass -File scripts\make-team-setup.ps1
```

It creates `%USERPROFILE%\.site-guard\site-guard-team-setup.ps1`, which installs the plugin and saves both private files for a teammate. **That file contains your secrets**, so share it only through a password manager, and never commit it. Teammates run it once, then delete it:

```
powershell -ExecutionPolicy Bypass -File .\site-guard-team-setup.ps1
```

They still need to connect Claude in Chrome and the Webflow connector themselves. If your settings change, make a new file, and have everyone run it again.

## Before your first run

1. **Site config (required):** copy `config/site-guard.example.yml` to `%USERPROFILE%\.site-guard\site-guard.yml` and fill it in, or get your team's copy. The plugin stops without it, and it never tests a site that isn't in that file.
2. **Claude in Chrome:** install the extension and connect it. It runs the checks in a new tab.
3. **Webflow connector:** connect it in Claude.
4. **Marketo (optional):** copy `.env.example` to `%USERPROFILE%\.site-guard\.env` and add your values. Don't put this file in OneDrive or a repo. Without it, form delivery is reported as not verified.

Chrome or Edge creates the PDF, and PowerShell, which comes with Windows, runs the scripts. Nothing else needs installing.

**Keep both files private.** Share them through a password manager, and never commit them.

## Reading the result

| Verdict | Meaning |
|---|---|
| `PASS` | Every check in scope ran, and this work added no issues |
| `BREAKING` | At least one breaking issue was found |
| `INCOMPLETE` | No breaking issue was found, but something couldn't be verified |

Reports are saved in `%USERPROFILE%\.site-guard\reports`.

## What it will and won't do

- It only clicks, types and submits on the configured dev site. Production is only read for comparison.
- It never publishes, and never changes Webflow, Marketo or a CRM.
- It only makes real form submissions on pages you worked on in the session, using your configured test address.
- It doesn't get around CAPTCHA.

**Real submissions are off by default.** Turn on `real_submissions.enabled` only after you've proven cleanup works.

Real submissions have real effects, such as confirmation emails, alerts and CRM records. List each form's effects in your config so people know before they run it. A Marketo trigger campaign, limited to the exact test address, should delete the test lead afterwards.

## Changing what it checks

- **Forms, flows and known differences:** your local `site-guard.yml`. A form that isn't listed is never submitted.
- **SEO and image rules:** `config/seo-rules.yml`.

## Known limits

- It only sees changes Claude made through the Webflow tools in the session's saved history. Tell Claude about any edits you made by hand.
- A new session can't see earlier work. The report then says so and marks the run `INCOMPLETE`.
- A `PASS` covers what was tested, not the whole site. The report's Coverage section shows what wasn't.
- The plugin can't see your CRM or helpdesk, so check those by hand.
- Windows only for now.

## Using a test lead safely

Set up cleanup and its protections yourself, and never test with a real customer's address. Deleting a person from Marketo with Remove from CRM on can't be undone, so limit the campaign to the exact test address.

No warranty. You're responsible for what you run against your own site.
