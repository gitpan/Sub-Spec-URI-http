package Sub::Spec::URI::http;

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use parent qw(Sub::Spec::URI);

use HTTP::Request;
use HTTP::Response;
use JSON;
use LWP::Debug;
use LWP::Protocol;
use LWP::UserAgent;

our $VERSION = '0.04'; # VERSION

our $Retries         = 3;
our $Retry_Delay     = 3;
our $LWP_Implementor = undef;
our $Log_Level       = undef;
our $Log_Callback    = undef;

my @logging_methods = Log::Any->logging_methods();
my $json = JSON->new->allow_nonref;

sub proto {
    "http";
}

sub _get_default_log_level {
    if ($ENV{LOG_LEVEL}) {
        return $ENV{LOG_LEVEL};
    } elsif ($ENV{TRACE}) {
        return "trace";
    } elsif ($ENV{DEBUG}) {
        return "debug";
    } elsif ($ENV{VERBOSE}) {
        return "info";
    } elsif ($ENV{QUIET}) {
        return "error";
    }
}

my $_req_counter = 0;
sub _req {
    my ($self, $ssreq) = @_;
    $log->tracef("-> _req(%s)", $ssreq);

    state $ua;
    if (!$ua) {
        $ua = LWP::UserAgent->new;
        $ua->env_proxy;
        $ua->set_my_handler(
            "response_data",
            sub {
                my ($resp, $ua, $h, $data) = @_;

                my $body     = $ua->{__body};
                my $in_body  = $ua->{__in_body};
                my $mark_log = $ua->{__mark_log};

                #$log->tracef("got resp: %s (%d bytes)", $data, length($data));
                # LWP::UserAgent can chop a single chunk from server into
                # several chunks
                if ($in_body) {
                    push @$body, $data;
                    return 1;
                }

                my $chunk_type;
                if ($mark_log) {
                    $data =~ s/(.)//;
                    $chunk_type = $1;
                } else {
                    $chunk_type = 'R';
                }
                if ($chunk_type eq 'L') {
                    if ($Log_Callback) {
                        $Log_Callback->($data);
                    } else {
                        $data =~ s/^\[(\w+)\]//;
                        my $method = $1;
                        $method = "error" unless $method ~~ @logging_methods;
                        $log->$method("[$self->{_uri}] $data");
                    }
                    return 1;
                } elsif ($chunk_type eq 'R') {
                    $in_body++;
                    push @$body, $data;
                    return 1;
                } else {
                    $body = ['[500, "Unknown chunk type from server: '.
                                 $chunk_type.'"]'];
                    return 0;
                }
            }
        );
    }

    # need to set due to closure?
    $ua->{__body}     = [];
    $ua->{__in_body}  = 0;

    my $req = HTTP::Request->new(POST => $self->{_uri});
    for (keys %$ssreq) {
        next if /\A(?:log_level|output_format|mark_log|args)\z/;
        my $hk = "X-SS-Req-$_";
        my $hv = $ssreq->{$_};
        if (!defined($hv) || ref($hv)) {
            $hk = "$hk-j-";
            $hv = $json->encode($hv);
        }
        $req->header($hk => $hv);
    }
    my $log_level = $Log_Level // $self->_get_default_log_level();
    $ua->{__mark_log} = $log_level ? 1:0;
    $req->header('X-SS-Req-Mark-Log' => $ua->{__mark_log});
    $req->header('X-SS-Req-Log-Level' => $log_level);
    $req->header('X-SS-Req-Output-Format' => 'json');

    my %args;
    if ($ssreq->{args}) {
        for (keys %{$ssreq->{args}}) {
            $args{$_} = $ssreq->{args}{$_};
        }
    }
    my $args_s = $json->encode(\%args);
    $req->header('Content-Type' => 'application/json');
    $req->header('Content-Length' => length($args_s));
    $req->content($args_s);

    #use Data::Dump; dd $req;

    my $attempts = 0;
    my $do_retry;
    my $http0_res;
    while (1) {
        $do_retry = 0;

        my $old_imp;
        if ($LWP_Implementor) {
            my $imp = $LWP_Implementor;
            $imp =~ s!::!/!g; $imp .= ".pm";
            $old_imp = LWP::Protocol::implementor("http");
            eval "require $imp" or
                return [500, "Can't load $LWP_Implementor: $@"];
            LWP::Protocol::implementor("http", $imp);
        }

        eval { $http0_res = $ua->request($req) };
        my $eval_err = $@;

        if ($old_imp) {
            LWP::Protocol::implementor("http", $old_imp);
        }

        return [500, "Client died: $eval_err"] if $eval_err;

        if ($http0_res->code >= 500) {
            $log->warnf("Network failure (%d - %s), retrying ...",
                        $http0_res->code, $http0_res->message);
            $do_retry++;
            sleep $Retry_Delay;
        }

        last unless $do_retry && $attempts++ < $Retries;
    }

    return [500, "Network failure: ".$http0_res->code." - ".$http0_res->message]
        unless $http0_res->is_success;
    return [500, "Empty response from server (1)"]
        if !length($http0_res->content);
    return [500, "Empty response from server (2)"]
        unless @{$ua->{__body}};

    my $res;
    eval {
        #$log->debugf("body: %s", $ua->{__body});
        $res = $json->decode(join "", @{$ua->{__body}});
    };
    my $eval_err = $@;
    return [500, "Invalid JSON from server: $eval_err"] if $eval_err;

    unless ($_req_counter++) {
        if ($Sub::Spec::URI::load_module_hook) {
            $Sub::Spec::URI::load_module_hook->($self);
        }
    }

    $log->tracef("<- successful _req()");
    #use Data::Dump; dd $res;
    $res;
}

sub _check {
}

sub _about {
    my ($self) = @_;
    unless (exists $self->{_about_cache}) {
        my $res = $self->_req({command => "about"});
        die "Can't get about from URL: $res->[0] - $res->[1]"
            unless $res->[0] == 200;
        die "Invalid about response from server: not a hash"
            unless ref($res->[2]) eq 'HASH';
        $self->{_about_cache} = $res->[2];
    }
    $self->{_about_cache};
}

sub module {
    my ($self) = @_;
    my $about = $self->_about;
    $about->{'module'};
}

sub sub {
    my ($self) = @_;
    my $about = $self->_about;
    $about->{'sub'};
}

sub args {
    my ($self) = @_;
    my $about = $self->_about;
    $about->{'args'} // {};
}

sub spec {
    my ($self) = @_;
    my $res = $self->_req({command => "spec"});
    $res->[2];
}

sub spec_other {
    my ($self, $other) = @_;
    my $res = $self->_req({command => "spec", %$other});
    $res->[2];
}

sub list_subs {
    my ($self, %args) = @_;
    my $res = $self->_req({command => "list_subs"});
}

# sub list_mods {}

sub call {
    my ($self, %args) = @_;
    $self->_req({command => "call", args => \%args});
}

sub call_other {
    my ($self, $other, %args) = @_;
    my $res = $self->_req({command => "call", args => \%args, %$other});
    $res->[2];
}

1;
# ABSTRACT: http (and https) scheme handler for Sub::Spec::URI


__END__
=pod

=head1 NAME

Sub::Spec::URI::http - http (and https) scheme handler for Sub::Spec::URI

=head1 VERSION

version 0.04

=head1 SYNOPSIS

 # specify module
 http://HOST/api/MOD::SUBMOD

 # specify module & sub name
 https://HOST/api/MOD::SUBMOD/FUNC

 # specify module, sub, and arguments
 http://HOST:5000/api/MOD::SUBMOD/FUNC?ARG1=VAL1&ARG2=VAL2

=head1 DESCRIPTION

HTTP server must implement L<Sub::Spec::HTTP> specification.

Since URL format can vary (e.g. some host might use
http://HOST/api/v1/MOD/SUBMOD/FUNC/arg1/arg2, some other might use
http://HOST/MOD::SUBMOD/FUNC?arg1=1&arg2=2, and so on), to determine module(),
sub(), and args(), an 'about' command is requested on the server to get
'server_url', 'module', 'sub', 'args' information. It is then cached.

=head1 CONFIGURATION

Some configuration is available in the following package variables:

=over 4

=item * $Retries => INT (default 3)

Number of retries to do on network failure. Setting it to 0 will disable
retries.

=item * $Retry_Delay => INT (default 3)

Number of seconds to wait between retries.

=item * LWP_Implementor => STR

If specified, use this class for http LWP::Protocol::implementor(). For example,
to access Unix socket server instead of a normal TCP one, set this to
'LWP::Protocol::http::SocketUnix'.

=item * $Log_Level => INT|STR

Request logging output from server. This will be sent in 'X-SS-Req-Log-Level'
HTTP request header. If not specified, default log level will be determined from
environment variable (like TRACE, DEBUG, etc).

=item * $Log_Callback => CODE

Pass log messages to this subroutine. If not specified, log messages will be
"rethrown" into Log::Any logging methods (e.g. $log->warn(), $log->debug(),
etc).

=back

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

