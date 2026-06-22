use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Extractor;
use App::PerlGraph::Resolver;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
sub add ($src, $file) {
    my $out = App::PerlGraph::Extractor->new(file_path => $file)->extract($parser->parse_string($src));
    $store->insert_node($_)       for @{ $out->{nodes} };
    $store->insert_edge($_)       for @{ $out->{edges} };
    $store->insert_unresolved($_) for @{ $out->{refs} };
}
# a base class + two subclasses, a heavily-called util, and an entry-point script
add("package App::Base;\nsub new { bless {}, shift }\nsub run { 1 }\n1;\n",                           'lib/App/Base.pm');
add("package App::Foo;\nuse parent -norequire, 'App::Base';\nsub go { App::Util::log(); App::Util::log() }\n1;\n", 'lib/App/Foo.pm');
add("package App::Bar;\nuse parent -norequire, 'App::Base';\nsub go { App::Util::log() }\n1;\n",       'lib/App/Bar.pm');
add("package App::Util;\nsub log { 1 }\n1;\n",                                                         'lib/App/Util.pm');
add("use App::Foo;\nApp::Foo->go;\n",                                                                  'bin/run.pl');
App::PerlGraph::Resolver->new(store => $store)->resolve_all;

my $o = App::PerlGraph::Query->new(store => $store)->overview;

ok +($o->{kinds}{package} // 0) + ($o->{kinds}{class} // 0) >= 4, 'scale counts the packages/classes';
ok +(grep { $_ eq 'bin/run.pl' } @{ $o->{scripts} }), 'entry-point script (.pl) is listed';

my ($util) = grep { ($_->{node}{qualified_name} // '') eq 'App::Util::log' } @{ $o->{central} };
ok $util && $util->{callers} >= 2, 'most-central includes the heavily-called util with its caller count';

my ($base) = grep { ($_->{node}{qualified_name} // '') eq 'App::Base' } @{ $o->{inherited} };
ok $base && $base->{subclasses} == 2, 'most-subclassed: App::Base has its 2 subclasses';

ok +(grep { $_->{ns} eq 'App::Base' } @{ $o->{namespaces} }), 'namespaces grouped by package';

my $txt = App::PerlGraph::Format::overview($o);
like $txt, qr/Codebase map/,                 'format: header';
like $txt, qr/Entry-point scripts/,          'format: entry points';
like $txt, qr/Most central/,                 'format: central section';
like $txt, qr/Most-subclassed/,              'format: subclassed section';
like $txt, qr/`App::Util::log` -- \d+ caller/, 'format: central symbol with caller count';

# empty graph: overview must render (not crash / not emit warnings), just a bare scale line
{
    my $empty = App::PerlGraph::Store->new(path => ':memory:'); $empty->init;
    my $o = App::PerlGraph::Query->new(store => $empty)->overview;
    my $et = App::PerlGraph::Format::overview($o);
    like $et, qr/Codebase map/,   'overview on an empty graph still renders the header';
    like $et, qr/0 files/,        '... with a zero-scale line and no crash';
}

done_testing;
