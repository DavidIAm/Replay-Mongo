package Replay::StorageEngine::Mongo;

use Moose;
with qw (Replay::Role::MongoDB Replay::Role::StorageEngine );
use Replay::IdKey;
use Readonly;
use JSON;
use Carp qw/croak carp/;
use Replay::Message::Reducable;
use Replay::Message::Cleared::State;
use Replay::Message::NoLock::DuringRevert;
use Replay::Message;

our $VERSION = 0.02;

sub retrieve {
    my ( $self, $idkey ) = @_;

    #    warn("Replay::StorageEngine::Mongo  retrieve $self, $idkey" );
    return $self->document($idkey);
}

sub absorb {

    my ( $self, $idkey, $atom, $meta ) = @_;

    #     warn("Replay::StorageEngine::Mongo  absorb $self, $idkey" );
    use JSON;
    my $r = $self->db->run_command(
        [   findAndModify => $idkey->collection(),
            query         => { idkey => $idkey->cubby },
            update        => {
                q^$^ . 'push' => { inbox => $atom },
                q^$^
                    . 'addToSet' => {
                    Windows => $idkey->window,
                    Timeblocks =>
                        { q^$^ . 'each' => $meta->{Timeblocks} || [] },
                    Ruleversions =>
                        { q^$^ . 'each' => $meta->{Ruleversions} || [] },
                    },
                q^$^
                    . 'setOnInsert' =>
                    { idkey => $idkey->cubby, IdKey => $idkey->pack },
                q^$^ . 'set' => { reducable_emitted => 1 },
            },
            fields   => { reducable_emitted => 1 },
            upsert   => 1,
            multiple => 0,
            new      => 0,
        ],
    );

    return $r;
}

# Locking states
# 1. unlocked ( lock does not exist )
# 2. locked unexpired ( lock set to a signature, lockExpired epoch in future )
# 3. locked expired ( lock est to a signature, lockExpired epoch in past )
# checkout allowed when in states (1) and sometimes (2) when we supply the
# signature it is currently locked with
# if is in state 2 and we don't have the signature, lock is unavailable
# if it is in state 3, we lock it with a temporary signature as an expired
# lock, revert its desktop to the inbox, then try to relock it with a new
# signature  If it relocks we are in state-2-with-signature and are able to
# check it out

sub checkin {
    my ( $self, $idkey, $uuid, $state ) = @_;

    # warn("Replay::StorageEngine::Mongo  checkin" );
    my $result = $self->update_and_unlock( $idkey, $uuid, $state );
    if ($self->collection($idkey)->delete_one(
            {   idkey     => $idkey->cubby,
                inbox     => { q^$^ . 'exists' => 0 },
                desktop   => { q^$^ . 'exists' => 0 },
                canonical => { q^$^ . 'exists' => 0 }
            }
        )
        )
    {
        $self->eventSystem->control->emit(
            Replay::Message::Cleared::State->new( $idkey->marshall ),
        );
    }
    return if not defined $result;
    return $result;
}

sub window_all {
    my ( $self, $idkey ) = @_;

    return {
        map { $_->{IdKey}->{key} => $_->{canonical} || [] }
            grep { defined $_->{IdKey}->{key} }
            $self->collection($idkey)->find(
            { idkey => { q^$^ . 'regex' => q(^) . $idkey->window_prefix } }
            )->all
    };
}

sub find_keys_need_reduce {

    my ($self) = @_;

    #    warn("Replay::StorageEngine::Mongo  find_keys_need_reduce $self" );
    my @idkeys = ();
    my $rule;
    while ( $rule
        = $rule ? $self->ruleSource->next : $self->ruleSource->first )
    {
        my $idkey = Replay::IdKey->new(
            name    => $rule->name,
            version => $rule->version,
            window  => q^-^,
            key     => q^-^
        );
        foreach my $result (
            $self->collection($idkey)->find(
                {   q^$^
                        . 'or' => [
                        { inbox           => { q^$^ . 'exists' => 1 } },
                        { desktop         => { q^$^ . 'exists' => 1 } },
                        { locked          => { q^$^ . 'exists' => 1 } },
                        { lockExpireEpoch => { q^$^ . 'exists' => 1 } }
                        ]
                },
                { idkey => 1 }
            )->all
            )
        {
            push @idkeys,
                Replay::IdKey->new(
                name    => $rule->name,
                version => $rule->version,
                Replay::IdKey->parse_cubby( $result->{idkey} )
                );
        }
    }
    return @idkeys;
}

sub checkout_record {
    my ( $self, $idkey, $signature, $timeout ) = @_;

    # try to get lock
    my $lockresult = $self->collection($idkey)->update_many(
        {   idkey   => $idkey->cubby,
            desktop => { q^$^ . 'exists' => 0 },
            inbox   => { q^$^ . 'exists' => 1 },
            q^$^
                . 'or' => [
                { locked => { q^$^ . 'exists' => 0 } },
                {   q^$^
                        . 'and' => [
                        { locked => $signature },
                        {   q^$^
                                . 'or' => [
                                {   lockExpireEpoch => { q^$^ . 'gt' => time }
                                },
                                {   lockExpireEpoch =>
                                        { q^$^ . 'exists' => 0 }
                                }
                                ]
                        }
                        ]
                }
                ]
        },
        {   q^$^
                . 'set' =>
                { locked => $signature, lockExpireEpoch => time + $timeout, },
            q^$^ . 'rename' => { 'inbox' => 'desktop' },
        },
    );

    return $self->lockreport($idkey);
}

sub lockreport {
    my ( $self, $idkey ) = @_;
    return $self->collection($idkey)->find_one( { idkey => $idkey->cubby },
        { locked => 1, lockExpireEpoch => 1, } );

    #        { locked => JSON::true, lockExpireEpoch => JSON::true } );
}

sub relock {
    my ( $self, $idkey, $current_signature, $new_signature, $timeout ) = @_;

    # Lets try to get an expire lock, if it has timed out
    my $unlockresult = $self->collection($idkey)->update_many(
        { idkey => $idkey->cubby, locked => $current_signature },
        {   q^$^
                . 'set' => {
                locked          => $new_signature,
                lockExpireEpoch => time + $timeout,
                },
        },
        { upsert => 0, new => 1, }
    );

    return $unlockresult;
}

sub relock_expired {
    my ( $self, $idkey, $signature, $timeout ) = @_;

    # Lets try to get an expire lock, if it has timed out
    my $unlockresult = $self->collection($idkey)->update_many(
        {   idkey  => $idkey->cubby,
            locked => { q^$^ . 'exists' => 1 },
            q^$^
                . 'or' => [
                { lockExpireEpoch => { q^$^ . 'lt'     => time } },
                { lockExpireEpoch => { q^$^ . 'exists' => 0 } }
                ]
        },
        {         q^$^
                . 'set' =>
                { locked => $signature, lockExpireEpoch => time + $timeout, },
        },
        { upsert => 0, new => 1, }
    );

    return $unlockresult;
}

sub relock_i_match_with {
    my ( $self, $idkey, $oldsignature, $newsignature ) = @_;
    my $unluuid      = $self->generate_uuid;
    my $unlsignature = $self->state_signature( $idkey, [$unluuid] );
    my $response     = $self->collection($idkey)->update_many(
        { idkey => $idkey->cubby, locked => $oldsignature, },
        {   q^$^
                . 'set' => {
                locked          => $unlsignature,
                lockExpireEpoch => time + $self->timeout,
                },
        },
        { upsert => 0, new => 1, }
    );
    if ( $response->matched_count == 0 ) {
        carp q(tried to do a revert but didn't have a lock on it);
        $self->eventSystem->control->emit(
            MessageType => 'NoLockDuringRevert',
            $idkey->hash_list,
        );
        return;
    }
    $self->revert_this_record( $idkey, $unlsignature );
    return $self->unlock( $idkey, $unluuid )->matched_count > 0;
}

sub revert_this_record {
    my ( $self, $idkey, $signature ) = @_;

    use Carp qw/cluck/;
    cluck 'REVERTING???';
    my $document = $self->retrieve($idkey);
    carp 'This document isn\'t locked with this signature ('
        . $document->{locked} . q/,/
        . $signature . ')'
        if $document->{locked} || q{} ne $signature;

    # reabsorb all of the desktop atoms into the document
    foreach my $atom ( @{ $document->{'desktop'} || [] } ) {
        $self->absorb( $idkey, $atom );
    }

    # and clear the desktop state
    my $unlockresult
        = $self->collection($idkey)
        ->update_many( { idkey => $idkey->cubby, locked => $signature } =>
            { q^$^ . 'unset' => { desktop => 1 } } );
    croak q(UNABLE TO RESET DESKTOP AFTER REVERT ) if $unlockresult->{n} == 0;
    return $unlockresult;
}

sub update_and_unlock {
    my ( $self, $idkey, $uuid, $state ) = @_;
    my $signature = $self->state_signature( $idkey, [$uuid] );
    my @unsetcanon = ();
    if ($state) {
        delete $state->{_id};       # cannot set _id!
        delete $state->{inbox};     # we must not affect the inbox on updates!
        delete $state->{desktop};   # there is no more desktop on checkin
        delete $state->{lockExpireEpoch}
            ;                       # there is no more expire time on checkin
        delete $state->{locked}
            ;    # there is no more locked signature on checkin
        if ( @{ $state->{canonical} || [] } == 0 ) {
            delete $state->{canonical};
            @unsetcanon = ( canonical => 1 );
        }
    }
    return $self->collection($idkey)->update_many(
        { idkey => $idkey->cubby, locked => $signature },
        {   ( $state ? ( q^$^ . 'set' => $state ) : () ),
            q^$^
                . 'unset' => {
                desktop         => 1,
                lockExpireEpoch => 1,
                locked          => 1,
                @unsetcanon
                }
        },
        { upsert => 0, new => 1 }
    );
}


sub _build_dbpass {    ## no critic (ProhibitUnusedPrivateSubroutines)
    my $self = shift;
    return $self->config->{StorageEngine}{Pass};
}

sub _build_dbuser {    ## no critic (ProhibitUnusedPrivateSubroutines)
    my $self = shift;
    return $self->config->{StorageEngine}{User};
}

sub _build_dbauthdb {    ## no critic (ProhibitUnusedPrivateSubroutines)
    my $self = shift;
    return $self->config->{StorageEngine}{AuthDB} || 'admin';
}

sub _build_dbname {      ## no critic (ProhibitUnusedPrivateSubroutines)
    my $self = shift;
    return $self->config->{stage} . '-replay';
}

1;

__END__

=pod

=head1 NAME

Replay::StorageEngine::Mongo - storage implementation for mongodb

=head1 VERSION

Version 0.04

=head1 DESCRIPTION

This is the Storage engine implementation for mongodb

=head1 SYNOPSIS


Replay::StorageEngine::Mongo->new( ruleSource => $rs, eventSystem => $es, config => { Mongo => { host: ..., port: ... } } );

=head1 OVERRIDES

=head2 retrieve - get document

=head2 absorb - add atom

=head2 checkout - lock and return document

=head2 revert - revert and unlock document

=head2 checkin - update and unlock document

=head2 window_all - get documents for a particular window

=head2 find_keys_need_reduce - find all the keys that look like they might need reduction

=head1 SUBROUTINES/METHODS

=head2 revert_this_record

reversion implementation

=head2 _build_uuid

make an object with which to generate uuids

=head2 collection

get the object for the db client that indicates the collection this document is in

=head2 document

return the document indicated by the idkey

=head2 generate_uuid

create and return a new uuid

=head2 checkout_record(idkey, signature)

This will return the uuid and document, when the state it is trying to open is unlocked and unexpired

otherwise, it returns undef.

=head2 relock(idkey, oldsignature, newsignature)

Given a valid oldsignature, updates the lock time and installs the new signature

returns the state document, or undef if signature doesn't match or it is not locked

=head2 relock_expired(idkey, signature)

will relock a state with an expired lock.

returns the state document, or undef if the state is not expired or is not locked

=head2 update_and_unlock(idkey, signature)

updates the state document, and unlocks the record.

returns the state document, or undef if the state is not locked with that signature

=head1 AUTHOR

David Ihnen, C<< <davidihnen at gmail.com> >>

=head1 CONFIGURATION AND ENVIRONMENT

Implied by context

=head1 DIAGNOSTICS

nothing to say here

=head1 DEPENDENCIES

Nothing outside the normal Replay world

=head1 INCOMPATIBILITIES

Nothing to report

=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to C<bug-replay at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Replay>.  I will be notified, and then you'

        ll automatically be notified of progress on your bug as I make changes .

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

Copyright 2014 David Ihnen.

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
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1;

=head1 STORAGE ENGINE MODEL ASSUMPTIONS

IdKey: object that indicates all the axis of selection for the data requested
Atom: defined by the rule being processed; storage engine shouldn't care about it.

STATE DOCUMENT GENERAL TO STORAGE ENGINE

inbox: [ Array of Atoms ] - freshly arrived atoms are stored here.
canonical: [ Array of Atoms ] - the current reduced 
canonSignature: q(SIGNATURE) - a sanity check to see if this canonical has been mucked with
Timeblocks: [ Array of input timeblock names ]
Ruleversions: [ Array of objects like { name: <rulename>, version: <ruleversion> } ]

STATE DOCUMENT SPECIFIC TO THIS IMPLEMENTATION

db is determined by idkey->ruleversion
collection is determined by idkey->collection
idkey is determined by idkey->cubby

desktop: [ Array of Atoms ] - the previously arrived atoms that are currently being processed
locked: q(SIGNATURE) - if this is set, only a worker who knows the signature may update this
lockExpireEpoch: TIMEINT - used in case of processing timeout to unlock the record

STATE TRANSITIONS IN THIS IMPLEMENTATION 

checkout

rename inbox to desktop so that any new absorbs don't get confused with what is being processed

=head1 STORAGE ENGINE IMPLEMENTATION METHODS 

=head2 (state) = retrieve ( idkey )

Unconditionally return the entire state record 

=head2 (success) = absorb ( idkey, message, meta )

Insert a new atom into the indicated state

=head2 (uuid, state) = checkout ( idkey, timeout )

if the record is locked already
  if the lock is expired
    lock with a new uuid
      revert the state by reabsorbing the desktop to the inbox
      clear desktop
      clear lock
      clear expire time
  else 
    return nothing
else
  lock the record atomically so no other processes may lock it with a uuid
    move inbox to desktop
    return the uuid and the new state

=head2 revert  ( idkey, uuid )

if the record is locked with this uuid
  if the lock is not expired
    lock the record with a new uuid
      reabsorb the atoms in desktop
      clear desktop
      clear lock
      clear expire time
  else 
    return nothing, this isn't available for reverting
else 
  return nothing, this isn't available for reverting

=head2 checkin ( idkey, uuid, state )

if the record is locked, (expiration agnostic)
  update the record with the new state
  clear desktop
  clear lock
  clear expire time
else
  return nothing, we aren't allowed to do this

=head2 lockreport ( idkey )

For debugging purposes - returns a string that shows the current state
of the lock on this record

=cut

1;
