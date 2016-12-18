use 5.8.8;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME               => 'Replay',
    AUTHOR             => q{David Ihnen <davidihnen@gmail.com>},
    VERSION_FROM       => 'lib/Replay/Role/MongoDB.pm',
    ABSTRACT           => 'Mongo support for the Replay framework',
    LICENSE            => 'Artistic_2_0',
    PL_FILES           => {},
    MIN_PERL_VERSION   => 5.8.8,
    CONFIGURE_REQUIRES => { 'ExtUtils::MakeMaker' => 0, },
    TEST_REQUIRES      => {
        'Test::Most'        => 0.33,
        'Test::Class' => 0,
        'Test::Mock::Class' => 0,
        'Test::Continuous'  => 0,
        'Test::Pod::Coverage' => 1.08,
        'Test::Pod' => 1.22,
        'Replay' => 0.03,
    },
    PREREQ_PM => {
        'Replay'                               => '0.03',
        'Carp'                                 => '1.3301',
        'File::Slurp'                          => '0',
        'File::Temp'                           => '0',
        'Data::Dumper'                         => '2.121_08',
        'Scalar::Util'                         => '1.46',
        'YAML'                                 => '0',
        'JSON'                                 => '2.53',
        'JSON::Any'                            => '1.29',
        'MongoDB'                              => 'v1.4.1',
        'MongoDB::OID'                         => 'v1.4.1',
        'Moose'                                => '2.1209',
        'Readonly'                             => '1.04',
        'Scalar::Util'                         => '1.21',
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES    => 'Replay-*' },
);
