#!/usr/bin/perl

use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec;
use DBI;

# ------------------------------------------------------------
# Project paths
# ------------------------------------------------------------

my $project_root = File::Spec->catdir(
    $Bin,
    '..'
);

my $report_script = File::Spec->catfile(
    $project_root,
    'scripts',
    'report_html.pl'
);

ok(
    -f $report_script,
    "HTML reporting script exists"
);

# ------------------------------------------------------------
# Temporary test environment
# ------------------------------------------------------------

my $temp_dir = tempdir(
    CLEANUP => 1
);

my $db_file = File::Spec->catfile(
    $temp_dir,
    'test.db'
);

my $html_file = File::Spec->catfile(
    $temp_dir,
    'report.html'
);

# ------------------------------------------------------------
# Create test database
# ------------------------------------------------------------

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$db_file",
    "",
    "",
    {
        RaiseError => 1,
        AutoCommit => 1,
    }
);

$dbh->do(q{
    CREATE TABLE jobs (
        job_id TEXT PRIMARY KEY,
        priority TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        total_attempts INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        completed_at TEXT
    )
});

# ------------------------------------------------------------
# Test data
#
# TEST-001:
#   SUCCESS
#   15 second elapsed interval
#
# TEST-002:
#   FAILURE
#   30 second elapsed interval
#
# TEST-003:
#   SUCCESS
#   20 second elapsed interval
#
# Average Retry Overhead:
#
#   Only SUCCESS jobs are included.
#
#   (15 + 20) / 2
#   = 17.5 seconds
#   = 17.50 seconds displayed
#
# Failure rate:
#
#   1 / 3 * 100
#   = 33.33%
#
# Completed today:
#
#   2 successful jobs
# ------------------------------------------------------------

$dbh->do(q{
    INSERT INTO jobs (
        job_id,
        priority,
        type,
        status,
        total_attempts,
        created_at,
        completed_at
    )
    VALUES (
        'TEST-001',
        'critical',
        'etch',
        'SUCCESS',
        1,
        '2026-08-16 10:00:00',
        '2026-08-16 10:00:15'
    )
});

$dbh->do(q{
    INSERT INTO jobs (
        job_id,
        priority,
        type,
        status,
        total_attempts,
        created_at,
        completed_at
    )
    VALUES (
        'TEST-002',
        'high',
        'inspection',
        'FAILURE',
        2,
        '2026-08-16 11:00:00',
        '2026-08-16 11:00:30'
    )
});

$dbh->do(q{
    INSERT INTO jobs (
        job_id,
        priority,
        type,
        status,
        total_attempts,
        created_at,
        completed_at
    )
    VALUES (
        'TEST-003',
        'low',
        'clean',
        'SUCCESS',
        1,
        '2026-08-16 12:00:00',
        '2026-08-16 12:00:20'
    )
});

$dbh->disconnect();

# ------------------------------------------------------------
# Run report generator
#
# Pass the database and output path explicitly so the test
# does not depend on the real project database.
# ------------------------------------------------------------

my $exit_code = system(
    $^X,
    $report_script,
    '--db',
    $db_file,
    '--output',
    $html_file,
);

$exit_code = $exit_code >> 8;

is(
    $exit_code,
    0,
    "HTML report command succeeds"
);

# ------------------------------------------------------------
# Verify output file
# ------------------------------------------------------------

ok(
    -f $html_file,
    "HTML report file is created"
);

# ------------------------------------------------------------
# Read generated HTML
# ------------------------------------------------------------

if (-f $html_file) {

    open my $fh, '<', $html_file
        or die "Cannot read '$html_file': $!";

    local $/;

    my $html = <$fh>;

    close $fh;

    # --------------------------------------------------------
    # Basic page checks
    # --------------------------------------------------------

    like(
        $html,
        qr/Job Reporting Dashboard/,
        "HTML contains dashboard title"
    );

    like(
        $html,
        qr/Jobs Completed Today/,
        "HTML contains completed-job metric"
    );

    like(
        $html,
        qr/>2</,
        "HTML contains completed-job count"
    );

    # --------------------------------------------------------
    # Retry overhead
    # --------------------------------------------------------

    like(
        $html,
        qr/Average Retry Overhead/,
        "HTML uses accurate retry-overhead label"
    );

    like(
        $html,
        qr/17\.50 sec/,
        "HTML contains correct average retry overhead"
    );

    unlike(
        $html,
        qr/17\\\.50/,
        "HTML does not contain an escaped decimal point"
    );

    # Make sure the old incorrect value is not still present.
    unlike(
        $html,
        qr/21\.67 sec/,
        "HTML does not contain the old average retry overhead"
    );

    # --------------------------------------------------------
    # Failure rate
    # --------------------------------------------------------

    like(
        $html,
        qr/33\.33%/,
        "HTML contains correct failure rate"
    );

    unlike(
        $html,
        qr/33\\\.33/,
        "HTML does not contain escaped failure rate"
    );

    # --------------------------------------------------------
    # Pending metric
    # --------------------------------------------------------

    like(
        $html,
        qr/Jobs Pending/,
        "HTML contains pending metric"
    );

    like(
        $html,
        qr/PENDING is not currently a legal database status/,
        "HTML preserves the pending-status explanation"
    );

    # --------------------------------------------------------
    # Job rows
    # --------------------------------------------------------

    like(
        $html,
        qr/TEST-001/,
        "HTML contains first test job"
    );

    like(
        $html,
        qr/TEST-002/,
        "HTML contains second test job"
    );

    like(
        $html,
        qr/TEST-003/,
        "HTML contains third test job"
    );

    like(
        $html,
        qr/SUCCESS/,
        "HTML contains SUCCESS status"
    );

    like(
        $html,
        qr/FAILURE/,
        "HTML contains FAILURE status"
    );

    like(
        $html,
        qr/Job Details/,
        "HTML contains job details table"
    );

    # --------------------------------------------------------
    # Timestamp
    # --------------------------------------------------------

    like(
        $html,
        qr/Report generated:/,
        "HTML contains report generation timestamp"
    );

    unlike(
        $html,
        qr/Report generated:[^\n]*\\[ :]/,
        "HTML timestamp contains no backslash escaping"
    );

    # --------------------------------------------------------
    # Placeholder regression checks
    #
    # The old implementation used bare PENDING as a placeholder.
    # That caused:
    #
    # PENDING is not currently a legal database status.
    #
    # to become:
    #
    # 0 is not currently a legal database status.
    #
    # The delimited {{PENDING_COUNT}} placeholder prevents that.
    # --------------------------------------------------------

    unlike(
        $html,
        qr/0 is not currently a legal database status/,
        "HTML does not corrupt the pending-status explanation"
    );

    unlike(
        $html,
        qr/\{\{[A-Z_]+\}\}/,
        "HTML contains no unresolved template placeholders"
    );
}

done_testing();