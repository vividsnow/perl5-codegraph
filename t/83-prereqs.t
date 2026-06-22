use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $dir = tempdir; $dir->child('lib')->mkpath; $dir->child('.pcg')->mkpath;
$dir->child('Makefile.PL')->spew_utf8(<<'PL');
use ExtUtils::MakeMaker;
WriteMakefile(
    NAME      => 'App',
    PREREQ_PM => { 'Foo::Bar' => 0, 'Unused::Dep' => '1.2' },
);
PL
$dir->child('lib/App.pm')->spew_utf8("package App;\nuse Foo::Bar;\nuse Needed::Mod;\n1;\n");
my $store = App::PerlGraph::Store->new(path => $dir->child('.pcg/graph.db')->stringify); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

my $r = $q->prereqs("$dir");
is $r->{source}, 'Makefile.PL',                              'parsed declared prereqs from Makefile.PL';
ok  +(grep { $_ eq 'Needed::Mod' } @{ $r->{missing} }),     'used-but-undeclared module -> MISSING';
ok !(grep { $_ eq 'Foo::Bar'     } @{ $r->{missing} }),     'a declared + used module is not missing';
ok  +(grep { $_ eq 'Unused::Dep' } @{ $r->{unused} }),      'declared-but-unused module is flagged';

my $txt = App::PerlGraph::Format::prereqs($r);
like $txt, qr/Missing.*Needed::Mod/s, 'format: the missing section names the undeclared dep';
like $txt, qr/unused.*Unused::Dep/s,  'format: the unused section names the unused dep';

# structured JSON metadata is preferred over Makefile.PL, and declaring a dep clears it
$dir->child('MYMETA.json')->spew_utf8('{"prereqs":{"runtime":{"requires":{"Foo::Bar":0,"Needed::Mod":0}}}}');
my $r2 = $q->prereqs("$dir");
is $r2->{source}, 'MYMETA.json',                            'structured JSON metadata wins over Makefile.PL';
ok !(grep { $_ eq 'Needed::Mod' } @{ $r2->{missing} }),     'declaring it in MYMETA.json clears the missing flag';

done_testing;
