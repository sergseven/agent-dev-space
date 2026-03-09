Alright, here's a coherent plan that starts lean, ships fast, and keeps the enterprise door open.

---

## The Product: **Personal agentic cloud workspace for developers**

One persistent Linux VM per user, pre-wired with agents, accessible from anywhere — local IDE, browser, or Telegram. You handle the infrastructure complexity so developers don't have to.

---

## Phase 1 — MVP (Weeks 1–8): Prove the core loop

**What you build:**

A single VM per user (Hetzner CX22, ~€4/mo), provisioned automatically on signup. Pre-installed: Claude Code, Codex CLI, tmux, Docker. VS Code tunnel running as a service from day one so the user connects their local IDE immediately. noVNC for browser-based desktop access. A Telegram bot that talks to Claude Code via `claude -p --resume` so sessions persist across messages.

**What you don't build yet:** billing, teams, multi-user, anything enterprise.

**The signup flow:** User pays → VM spins up in ~3 minutes → they get a Telegram bot token + a VS Code connection string + a noVNC URL. That's the entire onboarding.

**Tech stack:** Hetzner API for VM provisioning, Terraform or a simple Python script, Nginx for reverse proxy, Caddy for automatic HTTPS per subdomain (`user123.yourproduct.dev`), Clerk or Supabase Auth for login.

**Pricing:** $19/month. Covers your Hetzner cost (~$5) with healthy margin. No usage metering yet — keep it simple.

**Target users:** Developers who've complained "I need a Mac Mini to run OpenClaw 24/7." Go where they hang out — the OpenClaw Discord, r/ClaudeAI, Hacker News Show HN post.

---

## Phase 2 — Polish & Retention (Weeks 9–16): Make it sticky

Once you have 20–30 paying users you'll learn what breaks. Common issues will be: agent sessions dying unexpectedly, VM running out of disk, people wanting to SSH with their own keys, wanting to connect JetBrains not just VS Code.

**What you add:**
- SSH key management UI (paste your public key, access via standard SSH)
- JetBrains Gateway support — it's the same tunnel mechanism, just a different client
- VM resource upgrade option ($35/mo for more CPU/RAM)
- Simple web dashboard: VM status, restart button, storage usage, regenerate Telegram token
- Persistent agent memory via MCP memory server pre-installed on every VM

**What you still don't build:** anything that requires a sales call.

**Goal by end of Phase 2:** 50 paying users, $950 MRR, clear signal on what the top 3 requested features are.

---

## Phase 3 — Expand surface area (Months 4–6): More agents, more interfaces

By now you know which agent people actually use (probably Claude Code and whatever's trending). You add:

- **Background agent mode:** User assigns a GitHub issue or Jira ticket via Telegram/Slack, agent works autonomously, posts back when done. This is the "Devin lite" feature but running on *their* VM with *their* credentials.
- **Slack integration** alongside Telegram — many developers live in Slack at work and Telegram personally.
- **Scheduled agents:** cron-style tasks ("every morning, summarize my open PRs and post to Telegram").
- **MCP server marketplace:** pre-configured MCP servers the user can enable in one click — GitHub, Notion, Linear, their own internal APIs.

**Pricing tier:** $39/month for "Pro" (background agents, Slack, scheduling). Keep $19/month "Solo" tier alive.

**Goal:** $5k MRR, enough to validate whether this is a business or a side project.

---

## Phase 4 — The Enterprise Door (Month 6+): Small teams

If Phase 3 is working, you'll start getting inbound from small engineering teams — "can I get 5 of these for my team?" Don't ignore it.

The minimum enterprise feature set that unlocks team sales:
- **Team workspaces:** one admin, multiple VMs, shared billing
- **Shared codebase access:** all team VMs mount the same repo, agents can see the full codebase
- **Audit log:** what did the agent do, what commands ran, what files changed
- **SSO:** one SAML/OIDC integration covers most companies

You don't need to build all of this to start selling to teams. Find 2–3 CTOs at 20–50 person companies who are willing to pay $200–500/month for a 5-seat team plan and build exactly what they need. Avoid building for hypothetical enterprise requirements — build for the specific humans who are handing you money.

The European angle worth keeping in your back pocket: if you position "agents run in your region, your code never leaves EU infrastructure," you have a real story for GDPR-conscious companies that Devin, which runs in US-based cloud infrastructure, cannot match today.

---

## What to build in what order (honest priority)

1. VM provisioning + VS Code tunnel → this is the foundation, everything else is useless without it
2. Telegram bot → this is the "wow" moment that differentiates you from just selling a VPS
3. Payment (Stripe) + auto-provisioning → required to have a real business
4. noVNC browser desktop → nice to have, not critical for early adopters
5. Dashboard → people will live in VS Code and Telegram, not your dashboard
6. Background agents / Slack → Phase 3, after you have paying users who want it

---

## The honest risk register

**Anthropic ships first-party persistent cloud sessions** — your VS Code tunnel and noVNC features get commoditized. Mitigation: the Telegram/Slack messenger interface and multi-agent neutrality survive this. Anthropic won't wire Claude Code to Telegram or support Codex CLI on their platform.

**You're competing on infra with AWS/GCP** for the enterprise path — don't go there. Your moat is the agent wiring, the transformation knowledge, and the messenger UX, not the VM itself.

**Growth is slow without a viral loop** — a Show HN post and OpenClaw community posts can get you to 50 users, but scaling to 500 requires either a strong SEO play ("run Claude Code in the cloud" is a real search query today) or a product-led growth mechanic like "invite a teammate, get a month free."

**You'll want to quit at week 5** when the VM provisioning breaks at 2am and you have 12 users. The answer is: build the provisioning to be idempotent and observable from day one, and set user expectations that it's an early product. Paying users are forgiving if you communicate well.

---

## Numbers that make sense

- Month 2: 20 users × $19 = $380 MRR, proving the market exists
- Month 4: 80 users × avg $22 = $1,760 MRR, covering your own salary partially
- Month 6: 200 users × avg $28 = $5,600 MRR, real business
- Month 9: 2–3 small team contracts at $300/mo each + 300 solo users = $10k+ MRR

None of this requires VC money. Hetzner costs scale linearly with revenue. You stay profitable from month one if you price correctly.

---

The cleanest version of this product in one sentence: **"Your always-on AI engineering workspace — connect your IDE, talk to your agents on Telegram, and your VM keeps working when your laptop is off."** Build that, charge for it, and the enterprise path opens naturally as teams start asking for multi-seat plans.
