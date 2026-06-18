use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";

# A file with non-ASCII content must not crash indexing (wide-character regression:
# sha1_hex / the parser XS croak on wide chars, so we read raw bytes).
my $dir = tempdir;
$dir->child('U.pm')->spew_utf8("package U;\n# café -- déjà vu \x{20ac}\nsub greet { 'salut' }\n1;\n");
my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $idx = App::PerlGraph::Indexer->new(store => $store, root => "$dir");

my $ok = eval { $idx->index_all; 1 };
ok $ok, 'indexing a UTF-8 file does not crash' or diag $@;
ok scalar($store->nodes_by_qname('U::greet')), 'sub from the UTF-8 file is indexed';

# search returns symbols, not file nodes (file nodes are excluded from FTS)
my @hits = $store->search('U');
ok !(grep { $_->{kind} eq 'file' } @hits), 'search returns no file nodes (only symbols)';
done_testing;
