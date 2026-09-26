# Recover lost floors, groups and agents

A runbook for Claude, run from an external terminal (Git Bash) opened in this
folder:

```
claude "read RECOVER-CHATS.md and follow it"
```

It finds an earlier copy of ONE of the following and puts it back into the
data folder this app is reading now:
- a **floor** (Agents Workflow);
- a **group**;
- a single **agent** on a floor.

It never deletes anything, and it asks before every write.

---

## Rules for Claude

- **Ask first. Ask exactly two questions:**
  1. "What do you want back: a **floor**, a **group**, or a single **agent**?"
  2. "What is its name?" For an agent, also ask "Which floor was it on?"
     If they don't know, search every floor.

  Match names case-insensitively, and by **part of the name**: people type
  "retemplate" for an agent called "Retemplate Editor". If more than one
  thing matches, list them and ask which one. Don't restore more than the one
  thing asked for.
- **Read-only until the user says yes.** Every search and listing step below
  only reads.
- **Never delete, move or edit a source copy.** Backups the user keeps
  elsewhere are theirs. Read from them, never write to them.
- **Back up before writing**, and write only while the app is stopped
  (step 5).
- Use Git Bash syntax. Paths contain spaces and parentheses, so quote every
  path.

## Background: how the app stores this

| What | Where |
|---|---|
| Floors, their agents, and each agent's `sessionId` | `<data>/floors.json` → `{ "floors": [ { id, name, agents: [ { id, name, role, isBoss, reportsTo, sessionId, ... } ] } ] }` |
| Groups and their chats | `<data>/groups.json` → `{ "groups": [ { id, name, chats: [ { sessionId, cwd } ] } ] }` |
| Agent briefs | `<data>/briefs/<id>.md` |
| The chat conversations themselves | `~/.claude/projects/<folder>/<sessionId>.jsonl` (the app never deletes these) |

`<data>` is `<parent>\agentic\data`. The parent is Documents unless it was
changed in Settings → Data Folder.

A floor, group or agent that "disappeared" is almost always one of two things:
1. The app is reading a different data folder. This is the usual cause.
2. The file was overwritten, or the agent was removed from its floor.

The conversation files are nearly always still in `~/.claude/projects`.

## Step 1 — Ask

Ask the two questions from the rules: floor / group / agent, then the name
(and, for an agent, which floor). Say that you will only read until they
confirm a restore.

## Step 2 — Find the folder the app reads now

The folder this app belongs to is the one containing this file. Its settings
live under `%LOCALAPPDATA%\ChristopherOS\<id>\`, and the `<id>` is the one
whose `app-root.txt` names this folder.

```bash
HERE="$(cygpath -w "$(pwd)")"
for d in "$LOCALAPPDATA"/ChristopherOS/*/; do
  [ -f "$d/app-root.txt" ] && grep -qiF "$HERE" "$d/app-root.txt" && { echo "settings: $d"; cat "$d/data-root.json" 2>/dev/null; }
done
```

- If `data-root.json` exists, the parent is its `"parent"`. Otherwise the
  parent is Documents.
- If the app is running, it can also say this itself:
  `curl -s http://127.0.0.1:<MDV2_PORT from .env>/api/data-root`
  (look at `root`).

**Check the parent.** It must be the folder that CONTAINS `agentic`, not
`...\agentic` itself. A parent of `...\Documents\agentic` makes the app read
`Documents\agentic\agentic\data`, an empty folder, and every floor looks lost.

This mistake has happened on more than one machine. People pick the
`agentic` folder they see in Explorer.

- **Newer versions fix it themselves on start.** The app switches to the
  folder above, corrects the setting, and folds anything created in the
  doubled folder back in. It never overwrites and never touches the doubled
  copy, and it records the merge in `<data>/migrations.json` as
  `doubled-parent-recovery`. So first just restart the app, and check whether
  that brought everything back.
- **If it's still wrong**, the install is an older version. Tell the user,
  and offer to do the following after they confirm (app stopped, step 5):
  1. Back up `data-root.json`.
  2. Set its `"parent"` to the folder above.
  3. Carry over anything created while the app read the doubled folder. For
     example, a floor made today exists only in `...\agentic\agentic\data`.
     Show those entries, and for each one the user wants to keep, run the
     step 6 merge from the doubled `floors.json` / `groups.json` into the
     correct one. Otherwise they stop showing: still on disk, just no longer
     read.
  4. Restart the app.

This alone often brings everything back, so re-check before going on.

## Step 3 — Find every earlier copy

Search the likely places. Stay inside the user profile and skip
`node_modules` and `.git`:

```bash
cd "$USERPROFILE"
find Documents Videos Music Desktop OneDrive* Downloads 2>/dev/null \
  \( -name node_modules -o -name .git \) -prune -o \
  \( -iname 'floors.json*' -o -iname 'groups.json*' \) -print 2>/dev/null
```

- For a floor or an agent, look at the `floors.json*` files.
- For a group, look at the `groups.json*` files.

Also count names like `*.bak-*`, `*.before-*`, and old app folders'
`server/data/`. If nothing turns up, ask the user where they keep backups.
Don't widen the search to whole drives without asking.

## Step 4 — Show what each copy holds for that name

Run this on every file found. `<kind>` is `floor`, `group` or `agent`.
`<floor>` is optional and narrows an agent search to one floor.

```bash
node -e '
const fs=require("fs"),path=require("path"),os=require("os");
const [file,kind,want,floorWant]=process.argv.slice(1);
const j=JSON.parse(fs.readFileSync(file,"utf8"));
const seen=new Set(), root=path.join(os.homedir(),".claude","projects");
try{for(const p of fs.readdirSync(root))for(const f of fs.readdirSync(path.join(root,p)))if(f.endsWith(".jsonl"))seen.add(f.slice(0,-6))}catch{}
const has=id=>id?(seen.has(id)?"chat found":"no chat file"):"never started";
const eq=(a,b)=>(a||"").toLowerCase().includes((b||"").toLowerCase());   // part of the name
if(kind==="floor") for(const f of (j.floors||[]).filter(x=>eq(x.name,want)))
  {console.log("FLOOR",f.name,f.id,"agents:",f.agents.length,"updated:",f.updatedAt);f.agents.forEach(a=>console.log("   ",a.name,a.id,a.sessionId,has(a.sessionId)))}
if(kind==="group") for(const g of (j.groups||[]).filter(x=>eq(x.name,want)))
  {console.log("GROUP",g.name,g.id,"chats:",g.chats.length);g.chats.forEach(c=>console.log("   ",c.sessionId,has(c.sessionId)))}
if(kind==="agent") for(const f of (j.floors||[]).filter(x=>!floorWant||eq(x.name,floorWant)))
  for(const a of f.agents.filter(a=>eq(a.name,want)))
    console.log("AGENT",a.name,a.id,"on floor",f.name,f.id,"| role:",a.role,a.isBoss?"(boss)":"","| session:",a.sessionId,has(a.sessionId),"| floor updated:",f.updatedAt);
' "<file>" <kind> "<name>" "<floor>"
```

Present a short table: copy path, file date, what matched, and whether the
chat was found. Then recommend a copy: normally the newest one where the
chat is found (and, for a floor, the one with the most agents). Ask the user
which copy to restore from.

Show the live data folder (step 2) side by side, so the user sees exactly
what will change:
- Does that floor or group already exist there?
- For an agent, is its floor there? Is the agent already on it?

## Step 5 — Stop the app

Writes while the app runs get overwritten on its next save.

- Ask the user to close the app's window.
- Confirm it's stopped: `<data>/.owner.json` names a `pid`, and
  `tasklist //FI "PID eq <pid>"` must show no task. Also check that nothing
  is listening on its port: `netstat -ano | grep LISTENING | grep :<port>`.

## Step 6 — Back up, then restore that one thing

1. Back up the live file:
   `cp "<data>/floors.json" "<data>/floors.json.before-recover-$(date +%Y%m%d-%H%M%S)"`
   Use `groups.json` instead when restoring a group.

2. Merge only the chosen entry, keeping every other key and entry as it is.

   **Floor or group:**

```bash
node -e '
const fs=require("fs");
const [live,src,kind,id]=process.argv.slice(1);   // kind: floors | groups
const L=JSON.parse(fs.readFileSync(live,"utf8")), S=JSON.parse(fs.readFileSync(src,"utf8"));
const pick=(S[kind]||[]).find(x=>x.id===id); if(!pick) throw new Error("id not in source");
L[kind]=L[kind]||[];
const i=L[kind].findIndex(x=>x.id===id);
if(i>=0) L[kind][i]=pick; else L[kind].push(pick);
const tmp=live+".tmp-recover"; fs.writeFileSync(tmp,JSON.stringify(L,null,2)+"\n"); fs.renameSync(tmp,live);
console.log(i>=0?"replaced":"added",kind,pick.name);
' "<data>/floors.json" "<source floors.json>" floors "<floor id>"
```

   If an entry with that id already exists live, replace it only after the
   user confirms.

   **Agent:** put the one agent back onto its floor in the live file.
   - If the floor itself is missing live, stop. Tell the user the whole floor
     is gone, and offer to restore the floor instead.
   - If the agent reported to someone who is no longer on the live floor,
     attach it to the live floor's boss instead.
   - If an agent with the same id is already there, replace it only after
     the user confirms.

```bash
node -e '
const fs=require("fs");
const [live,src,floorId,agentId,liveFloorId]=process.argv.slice(1);
const L=JSON.parse(fs.readFileSync(live,"utf8")), S=JSON.parse(fs.readFileSync(src,"utf8"));
const sf=(S.floors||[]).find(f=>f.id===floorId); if(!sf) throw new Error("floor not in source");
const a=sf.agents.find(x=>x.id===agentId); if(!a) throw new Error("agent not in source floor");
const lf=(L.floors||[]).find(f=>f.id===(liveFloorId||floorId)); if(!lf) throw new Error("that floor is not in the live file: restore the floor instead");
const pick={...a};
if(pick.isBoss && lf.agents.some(x=>x.isBoss&&x.id!==pick.id)) pick.isBoss=false;          // one boss per floor
if(pick.reportsTo && !lf.agents.some(x=>x.id===pick.reportsTo)) pick.reportsTo=(lf.agents.find(x=>x.isBoss)||{}).id||null;
const i=lf.agents.findIndex(x=>x.id===pick.id);
if(i>=0) lf.agents[i]=pick; else lf.agents.push(pick);
lf.updatedAt=new Date().toISOString();
const tmp=live+".tmp-recover"; fs.writeFileSync(tmp,JSON.stringify(L,null,2)+"\n"); fs.renameSync(tmp,live);
console.log(i>=0?"replaced":"added","agent",pick.name,"on floor",lf.name);
' "<data>/floors.json" "<source floors.json>" "<source floor id>" "<agent id>" "<live floor id, if the floor id differs>"
```

   Pass the last argument only when the floor was recreated live under a new
   id. The user picks which live floor it goes onto.

3. **Reconnect an older chat.** An agent can come back pointing at a
   `sessionId` whose chat file is gone ("no chat file"), while another copy
   from step 4 has the SAME agent `id` with a different `sessionId` whose chat
   IS found. That's the agent's older conversation.
   - Tell the user the dates of both copies, and offer to point the agent at
     the older chat.
   - If they say yes, set that one agent's `sessionId` in the live file to the
     session whose chat was found. Back up first, and change nothing else:

```bash
node -e '
const fs=require("fs");
const [live,agentId,sessionId]=process.argv.slice(1);
const L=JSON.parse(fs.readFileSync(live,"utf8"));
const a=(L.floors||[]).flatMap(f=>f.agents).find(x=>x.id===agentId); if(!a) throw new Error("agent not in live file");
console.log("sessionId",a.sessionId,"->",sessionId); a.sessionId=sessionId;
const tmp=live+".tmp-recover"; fs.writeFileSync(tmp,JSON.stringify(L,null,2)+"\n"); fs.renameSync(tmp,live);
' "<data>/floors.json" "<agent id>" "<session id whose chat was found>"
```

   Don't do this when the missing session's chat might still turn up. Search
   first, in `~/.claude/projects` and in
   `%LOCALAPPDATA%\ChristopherOS\*\claude-isolated\projects`.

4. Briefs: for each agent restored (the one agent, or every agent on a
   restored floor), copy `<source data>/briefs/<id>.md` into `<data>/briefs/`
   **only if it isn't already there** (`cp -n`). Try both the agent's `id`
   and its `sessionId` as the file name.
5. Check that the live file still parses:
   `node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "<data>/floors.json" && echo ok`

## Step 7 — Start and confirm

1. Start the app with `Start.bat`.
2. Confirm that `curl -s http://127.0.0.1:<port>/api/floors` (or
   `/api/groups`) lists the floor, the group, or the agent on its floor.
3. Tell the user:
   - which copy was used;
   - where the backup of the old live file is;
   - what came back with its chat;
   - what came back without one ("no chat file" / "never started"). Those
     show the brief but no history.

If the terminal pane shows Claude's "Choose the text style" screen, that's
the app's separate Claude profile running for the first time. Press Enter
once; old conversations still open.
