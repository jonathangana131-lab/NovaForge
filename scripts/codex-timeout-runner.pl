#!/usr/bin/env perl
use strict;
use warnings;
use POSIX qw(:sys_wait_h setsid);
use Time::HiRes qw(CLOCK_MONOTONIC clock_gettime sleep);

my ($timeout, $log_path, @command) = @ARGV;
if (!defined $timeout || !defined $log_path || !@command) {
    die "usage: codex-timeout-runner.pl <seconds> <log-path> <command...>\n";
}

sub numeric_environment_value {
    my ($name, $default, $allow_zero) = @_;
    my $value = exists $ENV{$name} ? $ENV{$name} : $default;
    if ($value !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ || (!$allow_zero && $value <= 0)) {
        my $requirement = $allow_zero ? "a non-negative number" : "a positive number";
        die "$name must be $requirement\n";
    }
    return 0 + $value;
}

if ($timeout !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ || $timeout <= 0) {
    die "timeout must be a positive number\n";
}
$timeout = 0 + $timeout;

my $term_grace = numeric_environment_value("TIMEOUT_RUNNER_TERM_GRACE_SECONDS", 5, 1);
my $kill_grace = numeric_environment_value("TIMEOUT_RUNNER_KILL_GRACE_SECONDS", 5, 1);
my $poll_interval = numeric_environment_value("TIMEOUT_RUNNER_POLL_SECONDS", 0.1, 0);
my $heartbeat_interval = numeric_environment_value("TIMEOUT_RUNNER_HEARTBEAT_SECONDS", 30, 1);
my $snapshot_timeout = numeric_environment_value(
    "TIMEOUT_RUNNER_SNAPSHOT_SECONDS",
    1.5,
    0
);
# Deterministic harness seam. Production callers leave this at zero; the shell
# harness uses it to prove a wedged process enumerator cannot wedge cleanup.
my $snapshot_test_delay = numeric_environment_value(
    "TIMEOUT_RUNNER_SNAPSHOT_TEST_DELAY_SECONDS",
    0,
    1
);
my $label = $ENV{TIMEOUT_RUNNER_LABEL} // $command[0];
$label =~ s{.*/}{};

# Truncate before forking, then make every writer append. Opening the child's
# stream with ">" while the supervisor separately appended could allow a later
# child write to overwrite timeout diagnostics.
open my $truncate_fh, ">", $log_path or die "open $log_path failed: $!\n";
close $truncate_fh or die "close $log_path failed: $!\n";

sub append_log {
    my ($message) = @_;
    if (open my $fh, ">>", $log_path) {
        print {$fh} $message;
        close $fh;
    }
}

sub supervisor_message {
    my ($message) = @_;
    append_log($message);
    print STDERR $message;
}

my %signal_numbers = (
    HUP  => 1,
    INT  => 2,
    QUIT => 3,
    TERM => 15,
);
my $requested_signal;
for my $signal_name (keys %signal_numbers) {
    $SIG{$signal_name} = sub {
        $requested_signal //= $signal_name;
    };
}

# The readiness pipe closes the fork/setsid race. The parent does not start its
# deadline or forward a signal until the child confirms that its isolated
# process group and session exist.
pipe(my $ready_reader, my $ready_writer) or die "pipe failed: $!\n";
my $pid = fork();
die "fork failed: $!\n" unless defined $pid;

if ($pid == 0) {
    close $ready_reader;
    for my $signal_name (keys %signal_numbers) {
        $SIG{$signal_name} = "DEFAULT";
    }

    if (!setsid()) {
        syswrite($ready_writer, "ERROR setsid failed: $!\n");
        POSIX::_exit(126);
    }
    if (!open(STDOUT, ">>", $log_path)) {
        syswrite($ready_writer, "ERROR open $log_path failed: $!\n");
        POSIX::_exit(126);
    }
    if (!open(STDERR, ">&", \*STDOUT)) {
        syswrite($ready_writer, "ERROR redirect stderr failed: $!\n");
        POSIX::_exit(126);
    }

    syswrite($ready_writer, "READY\n");
    close $ready_writer;
    {
        no warnings "exec";
        exec { $command[0] } @command;
        print STDERR "exec $command[0] failed: $!\n";
        POSIX::_exit(127);
    }
}

close $ready_writer;
my $readiness = "";
while ($readiness !~ /\n/) {
    my $chunk = "";
    my $read_count = sysread($ready_reader, $chunk, 256);
    if (!defined $read_count) {
        next if $!{EINTR};
        last;
    }
    last if $read_count == 0;
    $readiness .= $chunk;
}
close $ready_reader;

if ($readiness ne "READY\n") {
    waitpid($pid, 0);
    my $detail = $readiness || "child exited before reporting readiness\n";
    die "timeout runner setup failed: $detail";
}

my %known_processes = ($pid => 1);
my $snapshot_unavailable = 0;
my %pending_snapshot_helpers;

sub reap_pending_snapshot_helpers {
    for my $helper_pid (keys %pending_snapshot_helpers) {
        my $done = waitpid($helper_pid, WNOHANG);
        delete $pending_snapshot_helpers{$helper_pid}
            if $done == $helper_pid || $done == -1;
    }
}

sub terminate_snapshot_helper {
    my ($helper_pid) = @_;
    kill "KILL", $helper_pid;

    # SIGKILL normally makes this immediate. Keep even helper reaping bounded:
    # a kernel-stuck `ps` must never become a second supervisor hang.
    my $reap_deadline = clock_gettime(CLOCK_MONOTONIC) + 0.1;
    while (1) {
        my $done = waitpid($helper_pid, WNOHANG);
        return 1 if $done == $helper_pid || $done == -1;
        last if clock_gettime(CLOCK_MONOTONIC) >= $reap_deadline;
        sleep(0.005);
    }
    $pending_snapshot_helpers{$helper_pid} = 1;
    return 0;
}

sub process_snapshot {
    my %processes;
    pipe(my $snapshot_reader, my $snapshot_writer)
        or return (undef, "could not create ps pipe: $!");

    my $snapshot_pid = fork();
    if (!defined $snapshot_pid) {
        close $snapshot_reader;
        close $snapshot_writer;
        return (undef, "could not fork ps helper: $!");
    }

    if ($snapshot_pid == 0) {
        close $snapshot_reader;
        for my $signal_name (keys %signal_numbers) {
            $SIG{$signal_name} = "DEFAULT";
        }
        if (!open(STDOUT, ">&", $snapshot_writer)) {
            POSIX::_exit(126);
        }
        close $snapshot_writer;
        open(STDERR, ">", "/dev/null");

        if (defined $ENV{TIMEOUT_RUNNER_SNAPSHOT_TEST_PID_FILE}
            && length $ENV{TIMEOUT_RUNNER_SNAPSHOT_TEST_PID_FILE}) {
            my $pid_fh;
            if (!open($pid_fh, ">>", $ENV{TIMEOUT_RUNNER_SNAPSHOT_TEST_PID_FILE})) {
                POSIX::_exit(126);
            }
            print {$pid_fh} "$$ snapshot\n";
            close $pid_fh or POSIX::_exit(126);
        }
        sleep($snapshot_test_delay) if $snapshot_test_delay > 0;

        # `sess` is the portable BSD/macOS ps name for the session id (`sid`
        # is accepted by procps but rejected by the macOS ps used by Xcode).
        {
            no warnings "exec";
            exec "/bin/ps", "-axo", "pid=,ppid=,pgid=,sess=,state=,comm=";
        }
        POSIX::_exit(127);
    }

    close $snapshot_writer;
    my $snapshot_deadline = clock_gettime(CLOCK_MONOTONIC) + $snapshot_timeout;
    my $output = "";
    my $snapshot_error;
    my $saw_eof = 0;

    while (!$saw_eof) {
        my $remaining = $snapshot_deadline - clock_gettime(CLOCK_MONOTONIC);
        if ($remaining <= 0) {
            $snapshot_error = "process snapshot exceeded ${snapshot_timeout}s";
            last;
        }

        my $read_set = "";
        vec($read_set, fileno($snapshot_reader), 1) = 1;
        my $ready = select($read_set, undef, undef, $remaining);
        if (!defined $ready) {
            next if $!{EINTR};
            $snapshot_error = "process snapshot select failed: $!";
            last;
        }
        if ($ready == 0) {
            $snapshot_error = "process snapshot exceeded ${snapshot_timeout}s";
            last;
        }

        my $chunk = "";
        my $read_count = sysread($snapshot_reader, $chunk, 64 * 1024);
        if (!defined $read_count) {
            next if $!{EINTR};
            $snapshot_error = "process snapshot read failed: $!";
            last;
        }
        if ($read_count == 0) {
            $saw_eof = 1;
            last;
        }
        $output .= $chunk;
    }
    close $snapshot_reader;

    my $snapshot_status;
    if (!defined $snapshot_error) {
        while (1) {
            my $done = waitpid($snapshot_pid, WNOHANG);
            if ($done == $snapshot_pid) {
                $snapshot_status = $?;
                last;
            }
            if ($done == -1) {
                $snapshot_error = "could not reap ps helper: $!";
                last;
            }
            my $remaining = $snapshot_deadline - clock_gettime(CLOCK_MONOTONIC);
            if ($remaining <= 0) {
                $snapshot_error = "process snapshot exceeded ${snapshot_timeout}s";
                last;
            }
            sleep($remaining < 0.005 ? $remaining : 0.005);
        }
    }

    if (defined $snapshot_error) {
        my $reaped = terminate_snapshot_helper($snapshot_pid);
        $snapshot_error .= "; ps helper did not reap promptly" unless $reaped;
        return (undef, $snapshot_error);
    }
    if (!WIFEXITED($snapshot_status) || WEXITSTATUS($snapshot_status) != 0) {
        return (undef, "ps exited unsuccessfully");
    }

    for my $line (split /\n/, $output) {
        next unless $line =~ /^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.*\S)\s*$/;
        $processes{$1} = {
            pid   => 0 + $1,
            ppid  => 0 + $2,
            pgid  => 0 + $3,
            sid   => 0 + $4,
            state => $5,
            comm  => $6,
        };
    }
    return (\%processes, undef);
}

sub active_tree_processes {
    my ($record_new) = @_;
    return {} if $snapshot_unavailable;
    my ($all_processes, $snapshot_error) = process_snapshot();
    if (!defined $all_processes) {
        append_log("[timeout-runner] $snapshot_error; falling back to process-group signaling.\n");
        $snapshot_unavailable = 1;
        return {};
    }

    my %selected;
    for my $candidate_pid (keys %known_processes) {
        $selected{$candidate_pid} = 1 if exists $all_processes->{$candidate_pid};
    }
    $selected{$pid} = 1 if exists $all_processes->{$pid};

    # Session/group membership catches the normal xcodebuild tree. Recursive
    # PPID closure from every known member also catches a compiler descendant
    # that creates its own process group or session.
    for my $candidate (values %{$all_processes}) {
        if ($candidate->{pgid} == $pid || $candidate->{sid} == $pid) {
            $selected{$candidate->{pid}} = 1;
        }
    }

    my $changed = 1;
    while ($changed) {
        $changed = 0;
        for my $candidate (values %{$all_processes}) {
            next if $selected{$candidate->{pid}};
            if ($selected{$candidate->{ppid}}) {
                $selected{$candidate->{pid}} = 1;
                $changed = 1;
            }
        }
    }

    my %active;
    for my $candidate_pid (keys %selected) {
        my $candidate = $all_processes->{$candidate_pid};
        next unless defined $candidate;
        next if $candidate->{state} =~ /^Z/;
        next if $candidate_pid == $$;
        $active{$candidate_pid} = $candidate;
        $known_processes{$candidate_pid} = 1 if $record_new;
    }
    return \%active;
}

sub signal_tree {
    my ($signal_name, $active) = @_;
    $active //= active_tree_processes(1);

    # Signal leaf processes before the root so escaped descendants remain
    # addressable by PID even if their parent exits immediately.
    my @process_ids = sort {
        ($a == $pid ? 1 : 0) <=> ($b == $pid ? 1 : 0)
            || $b <=> $a
    } keys %{$active};
    for my $process_id (@process_ids) {
        kill $signal_name, $process_id;
    }
    kill $signal_name, -$pid;
}

sub describe_survivors {
    my ($active) = @_;
    return "none" unless keys %{$active};
    return join(
        ", ",
        map {
            my $process = $active->{$_};
            "pid=$process->{pid} ppid=$process->{ppid} pgid=$process->{pgid} sid=$process->{sid} state=$process->{state} comm=$process->{comm}"
        } sort { $a <=> $b } keys %{$active}
    );
}

sub decoded_status {
    my ($status) = @_;
    return WEXITSTATUS($status) if WIFEXITED($status);
    return 128 + WTERMSIG($status) if WIFSIGNALED($status);
    return 1;
}

my $started_at = clock_gettime(CLOCK_MONOTONIC);
my $deadline = $started_at + $timeout;
my $next_heartbeat = $heartbeat_interval > 0 ? $started_at + $heartbeat_interval : undef;
my $child_reaped = 0;
my $child_status;
my $shutdown_exit_status;
my $shutdown_reason;
my $term_sent_at;
my $kill_sent_at;

while (1) {
    reap_pending_snapshot_helpers();
    if (!$child_reaped) {
        my $done = waitpid($pid, WNOHANG);
        if ($done == $pid) {
            $child_reaped = 1;
            $child_status = $?;
        } elsif ($done == -1) {
            $child_reaped = 1;
            $child_status = 1 << 8;
        }
    }

    my $now = clock_gettime(CLOCK_MONOTONIC);
    if (!defined $shutdown_reason && defined $requested_signal) {
        $shutdown_reason = "signal $requested_signal";
        $shutdown_exit_status = 128 + $signal_numbers{$requested_signal};
        supervisor_message("\n[timeout-runner] Received $requested_signal; terminating process tree $pid.\n");
    } elsif (!defined $shutdown_reason && !$child_reaped && $now >= $deadline) {
        $shutdown_reason = "timeout";
        $shutdown_exit_status = 142;
        supervisor_message("\n[timeout] Command exceeded ${timeout}s; terminating process tree $pid.\n");
    }

    if (!defined $shutdown_reason) {
        exit decoded_status($child_status) if $child_reaped;
    } else {
        if (!defined $term_sent_at) {
            my $active = active_tree_processes(1);
            supervisor_message("[timeout-runner] Sending TERM to process tree $pid.\n");
            signal_tree("TERM", $active);
            $term_sent_at = $now;
        }

        my $active = active_tree_processes(1);
        if ($child_reaped && !keys %{$active}) {
            supervisor_message("[timeout-runner] Process tree $pid is fully drained.\n");
            exit $shutdown_exit_status;
        }

        if (!defined $kill_sent_at && $now >= $term_sent_at + $term_grace) {
            supervisor_message("[timeout-runner] TERM grace expired; sending KILL to process tree $pid.\n");
            signal_tree("KILL");
            $kill_sent_at = $now;
        } elsif (defined $kill_sent_at && $now >= $kill_sent_at + $kill_grace) {
            $active = active_tree_processes(1);
            supervisor_message(
                "[timeout-runner] Final cleanup window expired; survivors: "
                    . describe_survivors($active)
                    . ".\n"
            );
            exit $shutdown_exit_status;
        }
    }

    if (defined $next_heartbeat && $now >= $next_heartbeat) {
        my $elapsed = int($now - $started_at);
        supervisor_message("[timeout-runner] HEARTBEAT $label: ${elapsed}s elapsed (cap ${timeout}s).\n");
        $next_heartbeat = $now + $heartbeat_interval;
    }

    sleep($poll_interval);
}
