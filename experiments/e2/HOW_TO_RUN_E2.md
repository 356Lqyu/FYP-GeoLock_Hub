# How to run E2 on a separate Supabase project (Windows, step by step)

E2 must **never** run on the Supabase project the Flutter app uses. It creates hundreds of test accounts, donations
and claims, empties the database between conditions and runs an unsafe claim on purpose. So E2 gets its **own new
Supabase project**. One project is enough for all three conditions, because each condition rebuilds the database
before it starts. The programs refuse to run on a project that has real user accounts.

## Step 1. Create the experiment project
1. Open <https://supabase.com/dashboard> and click **New project**.
2. Name it `geolock-e2-experiment`, region **Southeast Asia (Singapore)**.
3. Database password: click **Generate a password** (letters and digits only) and keep it in a safe place outside
   the repository.
4. Wait until the project is ready (about 2 minutes). Do not add tables or users yourself.

## Step 2. Copy the connection string
1. In the new project, click **Connect** at the top of the page.
2. Choose **Session pooler** (port **5432**). Do not use the Transaction pooler (port 6543), because it drops the NGO
   sign in between statements.
3. Copy the string and put your password in place of `[YOUR-PASSWORD]` (remove the brackets). It looks like
   `postgresql://postgres.abcdefghijklmnop:PASSWORD@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres`.
4. Check that the part after `postgres.` is the experiment project, not the app's project.

## Step 3. Python packages (once)
From the repository root `D:\fyp-combine\FYP-GeoLock_Hub`:
```powershell
py -m venv .venv
.venv\Scripts\activate
pip install -r experiments/requirements.txt
```

## Step 4. Run E2
The connection string from Step 2 is set in `experiments/e2/test_harness/e2_harness.py` (`DSN = ...`). If you create a new experiment project, change that one line. Then:
```powershell
python experiments/e2/run_e2.py
```
1. It runs baseline 1, baseline 2 and the proposed method, rebuilding the database before each, then the comparison.
2. Over the internet this takes roughly 15 to 30 minutes.
3. Open `experiments/e2/experiment_result/summary.md`. Its "Database" line should say "separate experiment only
   Supabase project".

What baseline 1 should show: **every** request is answered SUCCESS (850 of 850) and every trial ends with 2, 5 or
10 owners. This is intended: every NGO finishes its availability check before any NGO saves, which is the check
then save race the report describes. An older run in the combine branch showed some CONFLICT answers for baseline 1
because the NGOs' timing was left to chance there.

## Step 5. After the experiment
The result folders keep all numbers. You can pause or delete the experiment project in the dashboard
(Project Settings, General). The app's project is never touched.

## When the app's claim or recovery SQL changes
1. In the **app** project, open the SQL editor, run this and download the result as CSV (it only reads):
   ```sql
   select p.proname as function_name, pg_get_function_arguments(p.oid) as arguments,
          case when p.prosecdef then 'DEFINER' else 'INVOKER' end as security, pg_get_functiondef(p.oid) as definition
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' order by 1, 2;
   ```
2. Save it as `experiments/e2/database/deployed_snapshot/dev_public_functions_<date>.csv`, set `EXPORT` in
   `database/build_app_claim_layer.py` to it and run `python experiments/e2/database/build_app_claim_layer.py`.
3. Run Step 4 again.

## Troubleshooting

| Message | What to do |
| --- | --- |
| `password authentication failed` | wrong password, or the `[YOUR-PASSWORD]` brackets are still in the string |
| `this project has real user accounts` or `NOT_AN_EXPERIMENT_PROJECT` | you used the app's project. Stop and use the experiment project |
| `This database is not a Supabase project` | the string does not point to a Supabase project |
| `Max client connections reached` | another program is connected to the experiment project; close it and run again |
| `Benchmark file changed` | the benchmark CSV files must keep Windows line endings; restore them with `git checkout -- "benchmark dataset/dataset"` |
| `E2_STUB_CALLED` | a claim reached the routing part of recovery. This should not happen in E2; report it |
