package Sub::Spec::URI::https;
use parent qw(Sub::Spec::URI::http);

our $VERSION = '0.05'; # VERSION

sub proto {
    "https";
}

1;

__END__
=pod

=head1 NAME

Sub::Spec::URI::https

=head1 VERSION

version 0.05

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2012 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut

