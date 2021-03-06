package Replay::Role::MongoDB;

#all you need to get a Mogo up and running from blank unauthed
# - create a myUserAdmin
# use admin
# db.createUser( {
#       user: 'myUserAdmin',
#       pwd: 'abc123',
#       roles: [ { role: 'userAdminAnyDatabase', db: 'admin' } ] } )
# - enable user auth on the db and restart it (auth=true in mongodb.conf)
# - log in as that user
# mongo -u myUserAdmin -p abc123 admin
# - create the replay user
# db.createUser( { user: 'replayuser', pwd: 'replaypass', roles: [ { role:
# 'dbAdminAnyDatabase' ,db: 'admin' }, { role: 'readWriteAnyDatabase', db:
# 'admin' } ] } )

use Moose::Role;
use Carp qw/croak confess carp cluck/;
use MongoDB;
use MongoDB::OID;
use JSON;
requires(
    qw( _build_dbname
        _build_dbauthdb
        _build_dbuser
        _build_dbpass )
);

our $VERSION = q(0.01);

has db       => ( is => 'ro', builder => '_build_db',       lazy => 1, );
has dbname   => ( is => 'ro', builder => '_build_dbname',   lazy => 1, );
has dbauthdb => ( is => 'ro', builder => '_build_dbauthdb', lazy => 1, );
has dbuser   => ( is => 'ro', builder => '_build_dbuser',   lazy => 1, );
has dbpass   => ( is => 'ro', builder => '_build_dbpass',   lazy => 1, );

has mongo => (
    is      => 'ro',
    isa     => 'MongoDB::MongoClient',
    builder => '_build_mongo',
    lazy    => 1,
);

sub _build_db {          ## no critic (ProhibitUnusedPrivateSubroutines)
    my ($self) = @_;
    my $config = $self->config;
    my $db     = $self->mongo->get_database( $self->dbname );
    return $db;
}

sub _build_mongo {    ## no critic (ProhibitUnusedPrivateSubroutines)
    my ($self) = @_;
    my $db = MongoDB::MongoClient->new(
        db_name  => $self->dbauthdb,
        username => $self->dbuser,
        password => $self->dbpass
    );
    return $db;
}

sub collection {
    my ( $self, $idkey ) = @_;
    use Carp qw/confess/;
    confess 'WHAT IS THIS ' . $idkey if !ref $idkey;
    my $name = $idkey->collection();
    return $self->db->get_collection($name);
}

sub document {
    my ( $self, $idkey ) = @_;
    return $self->collection($idkey)->find( { idkey => $idkey->cubby } )
        ->next || $self->new_document($idkey);
}

1;

__END__

=pod

=head1 NAME

Replay::Role::MongoDB - Get Mongo up without duplication code

=head1 VERSION

Version 0.04

=head1 SYNOPSIS

 with qw(Replay::Role::MongoDB)

=head1 DESCRIPTION

Use this role to provide the shared implementation of mongo database access

=head1 SUBROUTINES/METHODS

requires (
    qw(_build_mongo
        _build_db
        _build_dbname
        _build_dbauthdb
        _build_dbuser
        _build_dbpass)
)

implements

=over 4

=head2 _build_mongo 

build the mongo connection handle

=head2 checkout_record 

given an IdKey, lock the document and return the uuid for the lock

=head2 collection 

given an IdKey, return the collection it will be found in

=head2 document 

given an IdKey, retrieve the document

=head2 lockreport 

given an IdKey, return a summary of its lock state

=head2 relock 

given an IdKey and a uuid, relock the record - presumably so that 
the timeout doesn't expire

=head2 relock_expired 

given an IdKey to a lock with an expired record, take over the lock

=head2 relock_i_match_with 

unclear how this varies from relock...

=head2 revert_this_record 

given an idkey to a locked record and its uuid key, revert this to its
unchecked out, unchanged state

=head2 update_and_unlock 

given an idkey to a locked record and its uuid key and a new 
canonical state, update canonical state clear desktop and unlock

=head1 AUTHOR

John Scoles, C<< <byterock  at hotmail.com> >>

=head1 CONFIGURATION AND ENVIRONMENT

Implied by context

=head1 DIAGNOSTICS

nothing to say here

=head1 DEPENDENCIES

Nothing outside the normal Replay world

=head1 INCOMPATIBILITIES

Nothing to report

=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to C<bug-replay at rt.cpan.org>, 
or through the web interface at 
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Replay>.  I will be 
notified, and then you'll automatically be notified of progress on your 
bug as I make changes .

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Replay


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Replay>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Replay>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Replay>

=item * Search CPAN

L<http://search.cpan.org/dist/Replay/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2015 John Scoles.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS 'AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1;
