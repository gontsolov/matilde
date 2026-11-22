# In-app feedback (UI-29)

**Send Feedback** in the apps (Mac: Help menu and Settings → General; iPhone: Settings) becomes an issue in Filip's Linear workspace. The flow: app → `POST /v1/feedback` on the sync server → Linear's GraphQL API.

## What is sent

Only what the user types: the kind (Bug, Idea, Something else), the message, an optional reply email and, if "Include app version and device" stays on, the app version and build, system version, device model and language setting. The sheet lists exactly those values. Never note content, never the account email, no analytics. A valid access token only makes the issue say "Signed in: yes"; the server doesn't look up who. The protocol is in [server/PROTOCOL.md](../server/PROTOCOL.md#feedback).

The server stores each submission in D1 first, then creates the issue. Once Linear has it, the text is deleted from D1 (the bookkeeping row goes after 30 days). If Linear is down or the key is missing, the app tells the user it's saved, and the cron retries every 15 minutes, up to 10 attempts.

The issue: title `[Feedback] Bug: <first 60 characters>`, description with the message, kind, reply email, "Signed in" and diagnostics. It goes to team **Gontsolov Labs** (GON), project **Matilde**, state **Triage**. Bugs get the **Bug** label and ideas get **Feature**. "Something else" gets no label.

## Already done

- Linear: the team, the Bug and Feature labels, the Matilde project, and Triage (Team settings → Triage) are set up. Their IDs are in `server/wrangler.jsonc` for staging and production: `LINEAR_TEAM_ID`, `LINEAR_LABEL_BUG`, `LINEAR_LABEL_IDEA`, `LINEAR_PROJECT_ID` and `LINEAR_STATE_ID`.
- `LINEAR_API_KEY` is set as a secret on staging and production.

## Owner steps left

1. **Approve the production deploy.** Merging the PR deploys staging automatically, including D1 migration `0003_feedback.sql`. Production waits for you: Actions → the Server run → **Review deployments** → `production` → Approve.
2. **Route feedback@matilde.page to your inbox.** It's the "Email Instead" fallback in the apps and the website footer's Feedback link. In Cloudflare: matilde.page → **Email** → **Email Routing** → **Routing rules** → **Create address**. Use the custom address `feedback`, action "Send to an email", and a verified destination (add and verify it under **Destination addresses** first). Email Routing is separate from the Email Sending that sign-in mail uses. Enabling it doesn't change sign-in.
3. **Test on staging.** It should return `201` with `"status":"sent"`, and an issue should show up in Triage:
   ```sh
   curl -X POST https://sync-staging.matilde.page/v1/feedback -H 'content-type: application/json' \
     -d '{"message":"Test from curl","kind":"bug","includeDiagnostics":false}'
   ```
   `503 feedback_not_configured` means the key or team is missing; `502 feedback_delivery_failed` means Linear refused the request (wrong key, or a label ID that doesn't belong to the team). Either way the row waits in D1. See [server/README.md](../server/README.md) (Operations) for the log events and how to list unsent rows.
4. **Check the sheets** on the Mac and the iPhone: sending, the "saved" state with sync offline, "Email Instead", the diagnostics disclosure, and light and dark mode.
5. *Optional:* **a "Feedback" label on every issue.** Create it in Linear (team GON). Look up its ID with the command below and put it in `LINEAR_LABEL_FEEDBACK` for staging and production in `server/wrangler.jsonc`. `LINEAR_LABEL_OTHER` works the same way for "Something else". Merging deploys it.

## Reference

**The API key.** Linear → Settings → Security & access → Personal API keys. Paste it **only** into the wrangler prompt, never into a chat, an issue or a file:

```sh
cd server
pnpm exec wrangler secret put LINEAR_API_KEY --env staging
pnpm exec wrangler secret put LINEAR_API_KEY --env production
```

**Looking up IDs** (team, labels, states, projects). Read the key into a shell variable without echoing it, so it doesn't end up in your shell history:

```sh
read -rs LINEAR_API_KEY && export LINEAR_API_KEY
curl -s https://api.linear.app/graphql -H "Authorization: $LINEAR_API_KEY" -H 'Content-Type: application/json' \
  -d '{"query":"{ teams { nodes { id name key labels { nodes { id name } } states { nodes { id name type } } } } projects { nodes { id name } } }"}'
```

`LINEAR_PROJECT_ID` and `LINEAR_STATE_ID` are optional. If Linear rejects them (for example, a state ID from another team, or Triage turned off in Team settings → Triage), the server creates the issue without them and logs `linear_placement_rejected`.

**Limits.**
- `FEEDBACK_PER_IP_HOUR`: 5 per hour per network.
- `GLOBAL_DAILY_FEEDBACK_CAP`: 200 a day on production, 50 on staging.

Both are vars in `server/wrangler.jsonc`. When the daily cap is hit, the server logs `global_feedback_cap_reached`; that's a good one for a Workers Observability alert.
