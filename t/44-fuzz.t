use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

# `pcg index` is fed whatever bytes are on disk. Indexing must never die/hang on
# adversarial or garbage input -- it must fail soft (skip what it can't make
# sense of) and keep going. tree-sitter is error-tolerant; the indexer must be too.
srand(42);
my @inputs = (
    "",                                          # empty
    "\0\0\0\0",                                  # NULs
    "package",                                   # truncated keyword
    "sub {",                                     # unbalanced
    "package " . ("A::" x 300) . "X;\n",         # absurd package name
    "sub " . ("x" x 4000) . " { 1 }\n",          # huge identifier
    "{" x 600,                                    # deep unbalanced nesting
    "use constant " . ("K=>1," x 800) . ";\n",   # huge constant list
    "\xff\xfe garbage \xc3\x28 \x80\x81\n",      # invalid byte sequences
    "package A;\n" . ('$x->y->z->w->v;' x 300),  # long method chains
    'q' . ('{' x 300),                            # unterminated quote-like
    "=pod\n" . ("blah " x 2000),                  # runaway POD, no =cut
);
push @inputs, join('', map { chr int rand 256 } 1 .. 1500) for 1 .. 25;   # random byte blobs

my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child("lib/f$_.pm")->spew_raw($inputs[$_]) for 0 .. $#inputs;

my $store = App::PerlGraph::Store->new(path => ':memory:'); $store->init;
my $ok = eval { App::PerlGraph::Indexer->new(store => $store, root => "$dir")->index_all; 1 };
ok $ok, 'index_all survives a directory full of adversarial / garbage files' or diag $@;

# robustness must not cost correctness: a good file alongside the garbage still indexes
$dir->child('lib/Good.pm')->spew("package Good;\nsub helper { 1 }\nsub run { helper() }\n1;\n");
my $s2 = App::PerlGraph::Store->new(path => ':memory:'); $s2->init;
eval { App::PerlGraph::Indexer->new(store => $s2, root => "$dir")->index_all };
ok scalar($s2->nodes_by_qname('Good::run')), 'a valid file is still indexed despite garbage neighbours';

done_testing;
