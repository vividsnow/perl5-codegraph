use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use Path::Tiny qw(tempdir);

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built";

# extraction: before/after/around -> modifier nodes + overrides edges
my $tree = $parser->parse_string(<<'PL');
package Widget;
use Moo;
sub render { 1 }
before 'render' => sub { my $self = shift; prep() };
around render => sub { my ($orig, $self) = @_; $self->$orig };
sub prep { 1 }
PL
my $out = App::PerlGraph::Extractor->new(file_path => 'W.pm')->extract($tree);

my @mods = grep { ($_->{metadata} || {})->{modifier} } @{ $out->{nodes} };
is scalar(@mods), 2, 'two modifier nodes (before + around)';
ok( (grep { (($_->{metadata} || {})->{modifier} // '') eq 'before' } @mods), 'before modifier present' );

my @ov = grep { $_->{kind} eq 'overrides' && $_->{provenance} eq 'framework' } @{ $out->{edges} };
is scalar(@ov), 2, 'two overrides edges';
ok( (grep { (($_->{metadata} || {})->{name} // '') eq 'Widget::render' } @ov), 'overrides target Widget::render' );

my ($prep_ref) = grep { $_->{reference_name} eq 'prep' } @{ $out->{refs} };
ok $prep_ref, 'modifier body call (prep) captured (scoped to the modifier)';

# e2e: the overrides edge resolves to the method node
my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/Widget.pm')->spew_utf8("package Widget;\nuse Moo;\nsub render { 1 }\nbefore 'render' => sub { 1 };\n1;\n");
my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$dir")->index_all;
my ($render) = $s->nodes_by_qname('Widget::render');
ok( (grep { $_->{provenance} eq 'framework' } $s->incoming_edges($render->{id}, 'overrides')),
    'overrides edge resolved onto Widget::render' );

# _moosey must not leak across packages in one file (review #1)
my $o2 = App::PerlGraph::Extractor->new(file_path => 'fb.pm')->extract(
    $parser->parse_string("package Foo;\nuse Moo;\npackage Bar;\nbefore 'x' => sub { 1 };\n"));
ok !(grep { ($_->{metadata} || {})->{modifier} } @{ $o2->{nodes} }),
    'no _moosey leak: a non-Moo package`s before-call is not a modifier';

# but `use Moo;` before the package still enables modifiers (file-level fallback)
my $o3 = App::PerlGraph::Extractor->new(file_path => 'baz.pm')->extract(
    $parser->parse_string("use Moo;\npackage Baz;\nsub r { 1 }\nbefore 'r' => sub { 1 };\n"));
ok( (grep { (($_->{metadata} || {})->{modifier} // '') eq 'before' } @{ $o3->{nodes} }),
    'use-before-package: modifier still detected' );

# a modifier AFTER a block-form moosey package is NOT detected: the block's
# `use Moo` state doesn't leak past its closing brace (block-scope fix x moosey).
my $o4 = App::PerlGraph::Extractor->new(file_path => 'blk.pm')->extract(
    $parser->parse_string("package P { use Moo; sub r { 1 } }\nbefore 'r' => sub { 1 };\n"));
ok( !(grep { ($_->{metadata} || {})->{modifier} } @{ $o4->{nodes} }),
    'modifier after a block-form moosey package is not detected (no moosey leak)' );
done_testing;
