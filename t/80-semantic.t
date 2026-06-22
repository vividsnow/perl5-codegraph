use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::Embed;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# A deterministic LOCAL fake embedder (no network, no model): each text becomes a fixed
# keyword-presence vector, so semantically-related identifiers share dimensions. This
# drives the whole --embed -> store -> semantic-rank pipeline reproducibly.
my $dir = tempdir;
my $fake = $dir->child('fake_embed.pl');
$fake->spew_utf8(<<'PL');
use v5.36;
my @kw = qw(validate check input user param render template save record db);
while (my $line = <STDIN>) {
    chomp $line; my $t = lc $line;
    print '[', join(',', map { $t =~ /\Q$_\E/ ? 1 : 0 } @kw), "]\n";
}
PL
local $ENV{PCG_EMBED_CMD} = qq{"$^X" "$fake"};   # quote $^X too: a perl path may contain spaces
local $ENV{PCG_EMBED_URL} = 'http://127.0.0.1:9';   # belt-and-suspenders: never hit a real endpoint

ok App::PerlGraph::Embed->available, 'a configured PCG_EMBED_CMD is an available provider';
my $v = App::PerlGraph::Embed->embed(['validate input']);
ok $v && @$v == 1 && @{ $v->[0] } == 10, 'the provider returns one vector of the right dim';

$dir->child('lib')->mkpath; $dir->child('.pcg')->mkpath;
$dir->child('lib/App.pm')->spew_utf8(<<'PL');
package App;
sub validate_input  { my $x = shift; $x }
sub check_user      { 1 }
sub render_template { 2 }
sub save_record     { 3 }
1;
PL
my $store = App::PerlGraph::Store->new(path => $dir->child('.pcg/graph.db')->stringify); $store->init;
App::PerlGraph::Indexer->new(store => $store, root => "$dir", embed => 1)->index_all;
ok $store->embedding_count >= 4, 'index --embed stored an embedding per named symbol';

my $q = App::PerlGraph::Query->new(store => $store);
my $r = $q->semantic('validate user input', 10);   # >= symbol count so every symbol is ranked (no tie cut off the asserted one)
ok $r->{results} && @{ $r->{results} }, 'semantic search returns ranked results';
is $r->{results}[0]{qualified_name}, 'App::validate_input', 'the closest symbol ranks first';
# the cosine score (not just the rank position) strictly separates a query-matching
# symbol from an unrelated one -- proves the embedding distinguishes them, not the tie-break.
my %score = map { ($_->{qualified_name} => $_->{_score}) } @{ $r->{results} };
ok $score{'App::render_template'} < $score{'App::validate_input'},
   'an unrelated symbol scores strictly below the query-matching one';

like App::PerlGraph::Format::semantic('validate input', $r),
     qr/Semantic search.*validate_input/s, 'format: renders the ranked list';

# provider DOWN at query time: embeddings exist, but the query can't be embedded
# (the command runs yet emits nothing -> embed() returns undef) -> the no_provider branch.
{
    local $ENV{PCG_EMBED_CMD} = qq{"$^X" -e0};   # quoted; produces no output -> embed() yields undef
    my $dr = $q->semantic('validate input');
    is $dr->{error}, 'no_provider', 'embeddings present but provider unreachable -> no_provider';
    like App::PerlGraph::Format::semantic('validate input', $dr),
         qr/provider unavailable/, 'format: provider-unavailable guidance (keyword fallback)';
}

# graceful degradation: a store with no embeddings returns a structured error and the
# formatter explains how to enable it (caller falls back to keyword search).
my $empty = App::PerlGraph::Store->new(path => ':memory:'); $empty->init;
my $er = App::PerlGraph::Query->new(store => $empty)->semantic('anything');
is $er->{error}, 'no_embeddings', 'no embeddings -> structured error, not a crash';
like App::PerlGraph::Format::semantic('x', $er), qr/index --embed/, 'format: points at `index --embed`';

# stale embeddings for a deleted symbol are pruned on re-embed
$dir->child('lib/App.pm')->spew_utf8("package App;\nsub validate_input { 1 }\n1;\n");
App::PerlGraph::Indexer->new(store => $store, root => "$dir", embed => 1)->index_all;
my %left = $store->all_embeddings;
my %byq  = map { ($store->node($_)->{qualified_name} // '') => 1 } keys %left;
ok !$byq{'App::render_template'}, 'an embedding for a since-deleted symbol is pruned';

done_testing;
