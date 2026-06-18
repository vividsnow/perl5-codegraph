use ExtUtils::MakeMaker;
WriteMakefile(
    NAME             => 'App::PerlGraph',
    VERSION_FROM     => 'lib/App/PerlGraph.pm',
    ABSTRACT         => 'Perl code knowledge graph for AI agents',
    AUTHOR           => 'vividsnow <vividsnow@pm.me>',
    LICENSE          => 'perl_5',
    MIN_PERL_VERSION => '5.036000',
    EXE_FILES        => ['bin/pcg'],
    PREREQ_PM        => {
        'Moo' => 0, 'Text::Treesitter' => 0, 'DBI' => 0,
        'DBD::SQLite' => '1.72', 'Cpanel::JSON::XS' => 0,
        'Path::Tiny' => 0, 'Path::Iterator::Rule' => 0,
        'Digest::SHA' => 0, 'POSIX' => 0, 'Exporter' => 0,
    },
    TEST_REQUIRES    => { 'Test2::V0' => 0 },
    META_MERGE       => {
        'meta-spec' => { version => 2 },
        prereqs => {
            runtime => { recommends => {
                'Devel::Symdump' => 0, 'Class::MOP' => 0,   # --runtime enrichment
                'Linux::Inotify2' => 0,                     # event-driven `pcg watch` on Linux
            } },
        },
        no_index => { directory => ['upstream', 'docs'] },
    },
);
