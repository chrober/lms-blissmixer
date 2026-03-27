package Plugins::BlissMixer::Survey;

#
# LMS Bliss Mixer - Metric Learning Survey
#
# Based on bliss-metric-learning by Polochon-street
# Adapted for LMS/BlissMixer by chrober
#
# Licence: GPL v3
#

use strict;

use DBI;
use File::Basename;
use File::Slurp qw(read_file write_file);
use HTTP::Status qw(RC_NOT_FOUND RC_OK RC_BAD_REQUEST RC_INTERNAL_SERVER_ERROR);
use JSON::XS qw(encode_json decode_json);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

my $log = logger('plugin.blissmixer');
my $prefs = preferences('plugin.blissmixer');

my $SURVEY_PAGE_RE = qr{blissmixer/survey\.html}i;
my $SURVEY_API_RE  = qr{blissmixer/survey-api}i;

my $dbPath;
my $matrixPath;
my $tripletsPath;

# bliss-learner binary (discovered via findbin)
my $learnerBinary;

# Learning process state
my $learner;
my $lastLearnerMsg = "";
my $learningStartTime = 0;
my $learningEndTime = 0;

use constant LEARNER_FINISHED_MSG => "FINISHED";
use constant CHECK_LEARNER_TIME => 60;
use constant MIN_LEARNER_RUN_TIME => 5;

sub init {
    $dbPath = shift;
    $matrixPath = shift;
    $tripletsPath = shift;

    # Discover bliss-learner binary (same pattern as Analyser.pm)
    $learnerBinary = Slim::Utils::Misc::findbin('bliss-learner');
    main::INFOLOG && $log->info("Learner: ${learnerBinary}") if $learnerBinary;

    Slim::Web::Pages->addRawFunction($SURVEY_PAGE_RE, \&_surveyPageHandler);
    Slim::Web::Pages->addRawFunction($SURVEY_API_RE, \&_surveyApiHandler);
    main::INFOLOG && $log->info("Survey handlers registered");
}

sub matrixPath {
    return $matrixPath;
}

sub cliCommand {
    my $request = shift;
    my $act = $request->getParam('act');

    if ($act eq 'status') {
        my $count = _countTriplets();
        my $matrixExists = (-e $matrixPath) ? 1 : 0;
        my $running = ($learner && $learner->alive) ? 1 : 0;
        $request->addResult("triplets", $count);
        $request->addResult("matrix_exists", $matrixExists);
        $request->addResult("learning", $running);
        if ($running) {
            $request->addResult("msg", $lastLearnerMsg);
        }
        if ($learningStartTime > 0) {
            $request->addResult("start", $learningStartTime);
            if ($running) {
                $request->addResult("duration", time() - $learningStartTime);
            } elsif ($learningEndTime > $learningStartTime) {
                $request->addResult("duration", $learningEndTime - $learningStartTime);
            }
        }
        if (!$learnerBinary) {
            $request->addResult("no_learner_binary", 1);
        }
        $request->setStatusDone();
    } elsif ($act eq 'update') {
        # Called by bliss-learner binary via JSON-RPC push notifications
        $lastLearnerMsg = $request->getParam('msg');
        main::DEBUGLOG && $log->debug("Survey learner update: $lastLearnerMsg");
        if ($lastLearnerMsg eq LEARNER_FINISHED_MSG) {
            _learningEnded();
        }
        $request->setStatusDone();
    } elsif ($act eq 'run-learning') {
        my $msg = _startLearning();
        $request->addResult("msg", $msg);
        $request->setStatusDone();
    } elsif ($act eq 'stop-learning') {
        _stopLearning();
        $request->addResult("msg", "stopped");
        $request->setStatusDone();
    } elsif ($act eq 'clear-training-data') {
        _clearTrainingData();
        $request->addResult("msg", "cleared");
        $request->setStatusDone();
    } else {
        $request->setStatusBadParams();
    }
}

# --- HTTP Handlers ---

sub _surveyPageHandler {
    my ($httpClient, $response) = @_;
    return unless $httpClient->connected;

    my $htmlFile = dirname(__FILE__) . "/HTML/EN/plugins/BlissMixer/survey.html";
    my $html = "";
    if (open(my $fh, '<', $htmlFile)) {
        local $/;
        $html = <$fh>;
        close($fh);
    } else {
        $html = "<html><body><h1>Error</h1><p>Could not load survey page.</p></body></html>";
        $log->error("Could not open survey page: $htmlFile");
    }

    $response->code(RC_OK);
    $response->content_type('text/html; charset=utf-8');
    $response->header('Connection' => 'close');
    $response->content($html);
    $httpClient->send_response($response);
    Slim::Web::HTTP::closeHTTPSocket($httpClient);
}

sub _surveyApiHandler {
    my ($httpClient, $response) = @_;
    return unless $httpClient->connected;

    my $request = $response->request;
    my $method = $request->method;
    my $uri = $request->uri;

    if ($method eq 'GET') {
        my ($action) = ($uri =~ /action=(\w+)/);
        $action ||= '';

        if ($action eq 'songs') {
            _handleGetSongs($httpClient, $response);
        } elsif ($action eq 'status') {
            _handleGetStatus($httpClient, $response);
        } else {
            _sendJson($httpClient, $response, RC_BAD_REQUEST, {error => "Unknown action: $action"});
        }
    } elsif ($method eq 'POST') {
        _handlePostTriplet($httpClient, $response, $request);
    } else {
        _sendJson($httpClient, $response, RC_BAD_REQUEST, {error => "Unsupported method"});
    }
}

sub _handleGetSongs {
    my ($httpClient, $response) = @_;
    my @songs = ();
    my $mediaDirs = Slim::Utils::Misc::getMediaDirs('audio');

    eval {
        my $dbh = DBI->connect("dbi:SQLite:dbname=${dbPath}", '', '', { RaiseError => 1, sqlite_unicode => 1 });
        # Fetch more than 3 in case some don't resolve to LMS tracks
        my $sth = $dbh->prepare("SELECT rowid, File, Title, Artist, Album FROM TracksV2 WHERE Ignore IS NOT 1 ORDER BY RANDOM() LIMIT 15");
        $sth->execute();
        while (my @row = $sth->fetchrow_array) {
            last if scalar(@songs) >= 3;
            my ($rowid, $file, $title, $artist, $album) = @row;
            my $trackObj = Plugins::BlissMixer::Plugin::_pathToTrack($mediaDirs, $file);
            if (blessed $trackObj) {
                push @songs, {
                    rowid     => int($rowid),
                    file      => $file,
                    title     => $title || 'Unknown Title',
                    artist    => $artist || 'Unknown Artist',
                    album     => $album || 'Unknown Album',
                    year      => $trackObj->year || 0,
                    audio_url => "/music/" . $trackObj->id . "/download",
                    track_id  => int($trackObj->id),
                };
            }
        }
        $sth->finish();
        $dbh->disconnect();
    };
    if ($@) {
        $log->error("Survey: failed to load songs: $@");
        _sendJson($httpClient, $response, RC_INTERNAL_SERVER_ERROR, {error => "Database error"});
        return;
    }

    if (scalar(@songs) < 3) {
        _sendJson($httpClient, $response, RC_INTERNAL_SERVER_ERROR,
            {error => "Not enough analyzed tracks in database (need at least 3, found " . scalar(@songs) . ")"});
        return;
    }

    _sendJson($httpClient, $response, RC_OK, {songs => \@songs});
}

sub _handleGetStatus {
    my ($httpClient, $response) = @_;
    my $count = _countTriplets();
    my $matrixExists = (-e $matrixPath) ? 1 : 0;
    _sendJson($httpClient, $response, RC_OK, {count => $count, matrix_exists => $matrixExists});
}

sub _handlePostTriplet {
    my ($httpClient, $response, $request) = @_;
    my $body = $request->content;
    my $data;

    eval { $data = decode_json($body); };
    if ($@ || !$data) {
        _sendJson($httpClient, $response, RC_BAD_REQUEST, {error => "Invalid JSON"});
        return;
    }

    my $song1 = $data->{song_1};
    my $song2 = $data->{song_2};
    my $oddOneOut = $data->{odd_one_out};

    if (!$song1 || !$song2 || !$oddOneOut) {
        _sendJson($httpClient, $response, RC_BAD_REQUEST, {error => "Missing song file paths"});
        return;
    }

    eval {
        my $triplets = _loadTriplets();
        push @$triplets, [$song1, $song2, $oddOneOut];
        _saveTriplets($triplets);
    };
    if ($@) {
        $log->error("Survey: failed to save triplet: $@");
        _sendJson($httpClient, $response, RC_INTERNAL_SERVER_ERROR, {error => "Failed to save triplet"});
        return;
    }

    my $count = _countTriplets();
    main::DEBUGLOG && $log->debug("Survey: saved triplet (similar: $song1, $song2; odd: $oddOneOut), total: $count");
    _sendJson($httpClient, $response, RC_OK, {ok => 1, count => $count});
}

# --- Learning Process Management ---

sub _startLearning {
    if ($learner && $learner->alive) {
        return "Learning already running";
    }

    if (!$learnerBinary) {
        return "bliss-learner binary not found. Cannot run metric learning.";
    }

    my $count = _countTriplets();
    if ($count < 10) {
        return "Not enough training data ($count triplets). Complete at least 10 survey rounds first.";
    }

    $lastLearnerMsg = "";
    $learningStartTime = time();
    $learningEndTime = 0;

    my $httpPort = preferences('server')->get('httpport') || 9000;

    my @params = ($learnerBinary, "--db", $dbPath, "--triplets", $tripletsPath,
                  "--output", $matrixPath,
                  "--lms", "127.0.0.1", "--json", $httpPort, "--notifs",
                  "--logging", "error");

    main::INFOLOG && $log->info("Starting metric learning: " . join(' ', @params));

    eval {
        require Proc::Background;
        $learner = Proc::Background->new(
            { 'die_upon_destroy' => 1 },
            @params
        );
    };
    if ($@) {
        $log->error("Survey: failed to start learning: $@");
        return "Failed to start learning process: $@";
    }

    # Health-check timer (same as Analyser.pm _checkAnalyser)
    _startLearnerCheckTimer();

    return "Learning started";
}

sub _stopLearning {
    if ($learner && $learner->alive) {
        $learner->die;
        main::INFOLOG && $log->info("Metric learning process stopped");
    }
    $learner = undef;
    Slim::Utils::Timers::killTimers(undef, \&_checkLearner);
}

sub _learningEnded {
    $learningEndTime = time();
    $learner = undef;
    Slim::Utils::Timers::killTimers(undef, \&_checkLearner);

    if (-e $matrixPath) {
        main::INFOLOG && $log->info("Metric learning complete. Matrix saved to $matrixPath");
        # Restart bliss-mixer so it picks up the new matrix
        Plugins::BlissMixer::Plugin::_stopMixer();
        main::INFOLOG && $log->info("bliss-mixer stopped; will restart with new matrix on next mix request");
    } else {
        $log->warn("Metric learning finished but no matrix file produced at $matrixPath");
    }
}

sub _startLearnerCheckTimer {
    Slim::Utils::Timers::killTimers(undef, \&_checkLearner);
    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + CHECK_LEARNER_TIME, \&_checkLearner);
}

sub _checkLearner {
    if ($learner && $learner->alive) {
        # Still running — reschedule the check
        _startLearnerCheckTimer();
        return;
    }

    # Process has exited — did we get a FINISHED notification?
    if ($lastLearnerMsg ne LEARNER_FINISHED_MSG) {
        # Died without sending FINISHED
        my $elapsed = time() - $learningStartTime;
        if ($elapsed > MIN_LEARNER_RUN_TIME) {
            $log->warn("Survey: bliss-learner exited unexpectedly after ${elapsed}s");
        }
        _learningEnded();
    }

    $learner = undef;
    Slim::Utils::Timers::killTimers(undef, \&_checkLearner);
}

# --- Triplet File Helpers ---

sub _loadTriplets {
    return [] unless -e $tripletsPath;
    my $json = read_file($tripletsPath, { binmode => ':utf8' });
    return decode_json($json);
}

sub _saveTriplets {
    my $triplets = shift;
    write_file($tripletsPath, { binmode => ':utf8' }, encode_json($triplets));
}

sub _countTriplets {
    return 0 unless -e $tripletsPath;
    my $triplets = eval { _loadTriplets() };
    return 0 if $@;
    return scalar @$triplets;
}

sub _clearTrainingData {
    if (-e $tripletsPath) {
        unlink $tripletsPath;
        main::INFOLOG && $log->info("Survey: deleted training triplets ($tripletsPath)");
    }
    if (-e $matrixPath) {
        unlink $matrixPath;
        main::INFOLOG && $log->info("Survey: deleted learned matrix ($matrixPath)");
        # Restart bliss-mixer so it stops using the old matrix
        Plugins::BlissMixer::Plugin::_stopMixer();
        main::INFOLOG && $log->info("bliss-mixer stopped; will restart without matrix on next mix request");
    }
}

sub _sendJson {
    my ($httpClient, $response, $code, $data) = @_;
    $response->code($code);
    $response->content_type('application/json; charset=utf-8');
    $response->header('Connection' => 'close');
    $response->content(encode_json($data));
    $httpClient->send_response($response);
    Slim::Web::HTTP::closeHTTPSocket($httpClient);
}

1;

__END__
