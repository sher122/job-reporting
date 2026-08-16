# Job Reporting Dashboard

SQLite-backed reporting for the Project 1 job automation system.

Project 2 takes the CSV attempt results produced by Project 1, reconstructs logical jobs and their retry history, stores the data in SQLite, and provides both a command-line report and an HTML dashboard for reviewing job outcomes.

---

## What This Project Is

This project is the reporting and persistence layer for a small job-automation system.

It is intended for someone who needs to turn execution logs from an automated job processor into structured data and quickly answer questions such as:

- How many jobs completed?
- How many attempts did they require?
- How many jobs failed?
- How much retry overhead occurred?
- Which jobs were processed?
- When did each job start and finish?

The project is deliberately separate from the job executor itself. Project 1 produces the raw results; Project 2 owns ingestion, persistence, aggregation, and reporting.

---

## Why It Exists

Project 1 produces a CSV result log containing individual job attempts.

That format is useful as an interchange log, but it is not a convenient long-term reporting model.

A retried job, for example, can appear as multiple CSV records:

```text
JOB-001 attempt 1 FAILURE
JOB-001 attempt 2 SUCCESS
```

A report consumer should not have to repeatedly reconstruct that history from raw CSV rows.

Project 2 solves that problem by:

1. importing every attempt into SQLite,
2. grouping attempts into logical jobs,
3. determining the final job status from the highest attempt,
4. recording when the first attempt occurred,
5. recording when the final attempt completed,
6. calculating reporting metrics from the resulting relational data.

The result is a small reporting pipeline with a clear boundary between execution and analysis.

---

## How It Works

The complete flow is:

```text
                PROJECT 1
             job-automation
                    |
                    v
             job_results.csv
                    |
                    v
        +-----------------------+
        |   CSV import layer    |
        |     import_csv.pl     |
        +-----------------------+
                    |
                    v
        +-----------------------+
        |        SQLite         |
        |                       |
        |  jobs                 |
        |  job_attempts         |
        +-----------------------+
                    |
          +---------+---------+
          |                   |
          v                   v
   report.pl            report_html.pl
      |                       |
      v                       v
 CLI dashboard           report.html
```

### Processing steps

1. Project 1 writes job-attempt results to `job_results.csv`.
2. `import_csv.pl` reads the CSV file.
3. Each attempt is stored in `job_attempts`.
4. Attempts belonging to the same `job_id` are reconstructed into a logical job in `jobs`.
5. The first attempt provides the logical job's `created_at`.
6. The highest attempt provides the final job status and `completed_at`.
7. Reporting queries aggregate the SQLite data.
8. `report.pl` displays the metrics in the terminal.
9. `report_html.pl` generates a standalone HTML dashboard.

---

## How to Run

### Requirements

The project requires Perl with the SQLite DBI driver available.

The main database is:

```text
db/job_reporting.db
```

The default Project 1 CSV input is:

```text
E:\Projects\job-automation\logs\job_results.csv
```

### Run the CSV Import

From the Project 2 directory:

```powershell
cd E:\Projects\job-reporting
perl scripts\import_csv.pl
```

A successful import looks like:

```text
Starting CSV import
CSV file: E:\Projects\job-automation\logs\job_results.csv
Database: E:\Projects\job-reporting\db\job_reporting.db
Loaded 19 CSV rows
Imported attempts: 19
Imported jobs:     15
Import completed successfully.
```

The importer rebuilds the reporting database from the CSV input each time it runs.

### Inspect the Database

```powershell
perl scripts\inspect_db.pl
```

Example:

```text
Total jobs:     15
Successful:     15
Failed:          0
Pending:        0
Total attempts: 19
```

### Run the CLI Report

```powershell
perl scripts\report.pl
```

Example:

```text
Job Reporting Dashboard
=======================

Jobs completed today: 15
Average Retry Overhead: 0.53 seconds
Failure rate:          0.00%
Jobs pending:          0
```

### Generate the HTML Dashboard

```powershell
perl scripts\report_html.pl
```

Open it:

```powershell
Start-Process .\report.html
```

The HTML dashboard contains completed-job count, average retry overhead, failure rate, pending count, and a full job-details table.

---

## Database Model

```text
jobs
 |
 +-- job_attempts
```

### `jobs`

| Column           | Purpose                        |
| ---------------- | ------------------------------ |
| `job_id`         | Logical job identifier         |
| `priority`       | Job priority                   |
| `type`           | Job type                       |
| `status`         | Final job status                |
| `total_attempts` | Number of attempts              |
| `created_at`     | Timestamp of the first attempt |
| `completed_at`   | Timestamp of the final attempt |

### `job_attempts`

| Column        | Purpose                            |
| ------------- | ----------------------------------- |
| `id`          | Attempt record ID                   |
| `job_id`      | Logical job identifier              |
| `attempt`     | Attempt number                      |
| `status`      | Result of that attempt              |
| `priority`    | Priority recorded for the attempt   |
| `type`        | Job type recorded for the attempt   |
| `recorded_at` | Timestamp recorded for the attempt  |

The schema enforces uniqueness on `(job_id, attempt)`, preventing duplicate attempt records.

---

## Reconstructing Logical Jobs

```text
JOB-001 | attempt 1 | FAILURE
JOB-001 | attempt 2 | SUCCESS
JOB-002 | attempt 1 | SUCCESS
```

becomes:

```text
jobs

JOB-001 | SUCCESS | attempts=2
JOB-002 | SUCCESS | attempts=1
```

while the individual attempts remain available in `job_attempts`.

### Final status rule

A job's final status comes from its highest attempt number:

```text
JOB-001 | attempt 1 | FAILURE
JOB-001 | attempt 2 | FAILURE
JOB-001 | attempt 3 | SUCCESS
```

produces:

```text
JOB-001 | SUCCESS | attempts=3
```

An intermediate failure is never mistaken for the job's final outcome.

### Timestamps

`created_at` comes from the first attempt; `completed_at` comes from the final attempt. The importer normalizes both Project 1's native timestamp format and the ISO format used in test fixtures.

---

## Reporting Metrics

### Jobs Completed Today

Counts logical jobs, not raw attempts, that completed successfully on the current SQLite local date. A retried job is never double-counted.

### Average Retry Overhead

Deliberately **not** called "Average Processing Time" — the database records when each attempt was logged, not how long it took to run.

The metric measures elapsed time between a successful job's first and final attempt, considering successful jobs only:

```text
Single-attempt successful job → 0 seconds retry overhead
Job that failed once, then succeeded → elapsed time between attempt 1 and attempt 2
```

Useful as a measure of time added by retries — not a measure of actual processing duration.

### Failure Rate

Calculated from logical jobs, not individual attempts. A job that failed twice before eventually succeeding still counts as a success.

### Jobs Pending

The current schema only permits `SUCCESS` and `FAILURE` as job statuses — `PENDING` is not yet a legal value. The report includes a pending-count query in anticipation of a future schema change, but under the current schema it always returns `0`. This is by design, not a bug.

---

## HTML Template Safety

The HTML generator uses explicitly delimited placeholders (`{{COMPLETED_TODAY}}`, `{{PENDING_COUNT}}`, etc.) rather than bare tokens. This matters concretely: an earlier version used the bare word `PENDING` as a placeholder, which accidentally corrupted an explanatory sentence in the dashboard that also contained the word "PENDING." The delimited format, plus a runtime check that fails loudly if any `{{...}}` token is left unresolved, prevents that class of bug from recurring silently.

---

## Data Integrity

Each import is transactional and rebuilds the database from the current CSV rather than appending incrementally — repeated imports are deterministic and never duplicate records.

The database enforces a unique constraint on `(job_id, attempt)`. If a CSV ever contained a duplicate attempt record, the import transaction fails and rolls back entirely, rather than silently dropping the duplicate row. Failing the whole import is treated as safer than partially applying uncertain data.

---

## CSV Input

Project 2 is the CSV **consumer**; Project 1 is the producer. The importer correctly handles Project 1's CSV quoting rules, including comma-containing fields — a `type` like `clean, inspection` is preserved as a single field rather than misread as two columns.

---

## Known Limitations

**CSV records must occupy one physical line.** Project 1's CSV writer can technically produce a valid, RFC-compliant record with an embedded newline inside a quoted field, but Project 2's reader processes the file one physical line at a time and doesn't currently reassemble multi-line records. In practice, `type` values in this project are short single-line strings, so this hasn't been an issue — but it's a known gap, not an oversight.

**Pending jobs aren't supported by the schema.** `PENDING` isn't yet a legal `jobs.status` value; adding it would require a schema change plus corresponding importer and reporting updates.

**Retry overhead is not processing duration.** The data model only has attempt timestamps, not per-attempt execution time, so "Average Retry Overhead" measures elapsed time across retries — not actual work done.

**The HTML dashboard is a static file**, not a live application. Refresh it by re-running the import and generator:

```powershell
perl scripts\import_csv.pl
perl scripts\report_html.pl
```

---

## Design Decisions

**SQLite instead of querying the CSV directly.** CSV is a fine interchange format but awkward for relational reporting — SQLite gives structured tables, constraints, SQL aggregation, and a clean separation between raw attempts and reconstructed jobs, all without a database server.

**Two tables instead of one.** Keeping `jobs` and `job_attempts` separate preserves the distinction between "what happened to the job overall" and "what happened on each attempt" — a single flattened table would make retry history awkward to query.

**Full rebuild on import, not incremental append.** Simpler and fully deterministic for this project's scope; a production-scale system would likely track ingestion offsets or event IDs instead.

**Fail loudly on duplicate attempts**, rather than silently discarding them — favors data integrity over convenience.

**CLI and HTML reports share the same database and the same queries**, so there's one reporting model, not two.

**Static HTML instead of a web framework.** Gives a real visual dashboard without pulling in HTTP routing, an application server, auth, or frontend tooling that this project's scope doesn't need.

---

## What Was Deliberately Not Built

Real-time updates, a running web server, authentication, multi-user access, remote database infrastructure, incremental event-stream ingestion, arbitrary multi-line CSV parsing, a `PENDING` schema state, interactive filtering, historical trend charts, configurable time zones, and production-scale data retention.

None of these are accidental gaps — the goal was a reliable local reporting pipeline over Project 1's existing CSV output, not a deployable product.

---

## Testing

Run tests from `E:\Projects\job-reporting`.

### Schema Tests

```powershell
perl tests\test_schema.pl
```

**29/29 passing.** Covers schema existence, SQLite connectivity, table creation, required columns, removal of the unreachable `INVALID` status, and the `(job_id, attempt)` unique constraint.

### Import Tests

```powershell
perl tests\test_import.pl
```

Covers CSV import, database connection, attempt import, logical-job reconstruction, final-status-from-highest-attempt, retry reconstruction, comma-containing job types, timestamp normalization, repeated-import behavior, and duplicate-attempt rejection. (The duplicate-attempt test intentionally triggers a `UNIQUE constraint failed` message from SQLite — that's the expected, correct outcome, not a failure.)

### CLI Report Tests

```powershell
perl tests\test_report.pl
```

Verifies the reporting calculations against known fixture data.

### HTML Report Tests

```powershell
perl tests\test_report_html.pl
```

Covers dashboard generation, all four metric values, the retry-overhead terminology and calculation, the pending-status explanation, job rows, status rendering, the report timestamp, and regression checks for two previously-found bugs: escaped-character corruption in numeric output, and placeholder-collision corruption of explanatory text.

---

## Project Structure

```text
job-reporting/
|
+-- db/
|   +-- job_reporting.db
|
+-- scripts/
|   +-- import_csv.pl
|   +-- inspect_db.pl
|   +-- report.pl
|   +-- report_html.pl
|
+-- tests/
|   +-- test_schema.pl
|   +-- test_import.pl
|   +-- test_report.pl
|   +-- test_report_html.pl
|
+-- schema.sql
+-- README.md
+-- .gitignore
```

The generated database and generated HTML report are runtime artifacts and are excluded from source control.

---

## Typical Workflow

```powershell
# Project 1
cd E:\Projects\job-automation
perl automation.pl

# Project 2
cd E:\Projects\job-reporting
perl scripts\import_csv.pl
perl scripts\inspect_db.pl
perl scripts\report.pl
perl scripts\report_html.pl
Start-Process .\report.html
```

---

## Project Boundary

**Project 1 owns:** job definition → validation → priority scheduling → execution → retries → CSV result generation.

**Project 2 owns:** CSV ingestion → attempt persistence → logical-job reconstruction → SQL reporting → CLI dashboard + HTML dashboard.

Project 2 never executes jobs. Project 1 never touches SQLite. Either side can evolve independently as long as the CSV contract between them holds.

---

## What This Project Demonstrates

Perl scripting and application structure · SQLite database design · DBI / DBD::SQLite · relational modeling · CSV parsing and ingestion · transactional database operations · unique constraints · retry-aware data reconstruction · timestamp normalization · SQL aggregation · command-line reporting · static HTML generation · regression testing · data-integrity testing · explicit handling of known limitations · separation of execution and reporting concerns

---

## What I Would Extend Next

1. Support a real `PENDING` state.
2. Replace the line-oriented CSV reader with a multi-line-aware parser.
3. Add richer historical/trend reporting and filtering by priority, type, status, and date range.
4. Add actual per-attempt processing-duration data to Project 1 so Project 2 can report true processing time, not just retry overhead.
5. Move from static HTML to an interactive web app if live or multi-user reporting becomes a requirement.
6. Replace full-database reloads with incremental ingestion for larger datasets.

---

## Relationship to Project 1

```text
PROJECT 1                    PROJECT 2
job-automation                job-reporting

Execute jobs                  Read CSV
Retry failures     --CSV-->   Store in SQLite
Write CSV                     Reconstruct jobs
                               Calculate metrics
                               Generate reports
```

Together: **Execute → Record → Import → Store → Report.**

---

This project is provided for educational and portfolio purposes.
