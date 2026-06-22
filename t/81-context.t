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

my $dir = tempdir; $dir->child('lib')->mkpath; $dir->child('t')->mkpath; $dir->child('.pcg')->mkpath;
$dir->child('lib/App.pm')->spew_utf8(<<'PL');
package App;
sub run { my $self = shift; helper(); util() }
sub helper { 1 }
sub util   { 2 }
1;
PL
$dir->child('t/run.t')->spew_utf8("App::run();\n");   # a test that reaches App::run
my $store = App::PerlGraph::Store->new(path => $dir->child('.pcg/graph.db')->stringify); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all;
my $q = App::PerlGraph::Query->new(store => $store);

# --- a working set for App::run: focus + project callees (for source) + covering tests ---
my $ctx = $q->context('App::run');
is scalar @{ $ctx->{focus} }, 1,                        'one focus symbol';
is $ctx->{focus}[0]{node}{qualified_name}, 'App::run',  'focus is App::run';
my %callee = map { ($_->{qualified_name} => 1) } @{ $ctx->{callees} };
ok $callee{'App::helper'} && $callee{'App::util'},      'both project callees gathered for source inclusion';
ok +(grep { m{t/run\.t} } @{ $ctx->{tests} }),          'covering test gathered';

my $txt = App::PerlGraph::Format::context($ctx, "$dir");
like $txt, qr/## Context: App::run/,        'format: header';
like $txt, qr/sub run \{/,                  'format: focus source';
like $txt, qr/### Callee definitions/,      'format: callee-definitions section';
like $txt, qr/sub helper \{/,               'format: a project callee\'s source is inlined';

# --- budget truncation: a tiny budget shows >=1 callee and omits the rest with a note ---
my $small = App::PerlGraph::Format::context($ctx, "$dir", 200);
like $small, qr/omitted for budget/,        'budget truncation note';
like $small, qr/sub run \{/,                'the focus is always kept even under a tiny budget';

# --- a non-symbol arg is routed through search (the NL-query mode) ---
my $nl = $q->context('a descriptive phrase that is not a symbol');
is $nl->{via}, 'search',                    'a non-symbol arg routes through search (no embeddings -> keyword)';

# --- nothing matched -> empty context renders cleanly ---
my $nf = $q->context('zzz_no_such_term_xyz');
is scalar @{ $nf->{focus} }, 0,             'a query with no hits -> empty focus';
like App::PerlGraph::Format::context($nf, "$dir"), qr/_not found_/, 'format: not found';

done_testing;
