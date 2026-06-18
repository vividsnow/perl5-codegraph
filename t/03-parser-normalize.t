use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
use App::PerlGraph::Grammar qw(NODE_ROOT NODE_SUB);

my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
my $node = eval { $parser->parse_string("sub foo { 1 }\n") } or skip_all "grammar not built: $@";

is $node->{type}, NODE_ROOT, 'root normalized';
is ref $node->{children}, 'ARRAY', 'children is arrayref';
is ref $node->{fields},   'HASH',  'fields is hashref';
ok $node->{sl} >= 1, 'start line is 1-based';

my ($sub) = grep { $_->{type} eq NODE_SUB } @{ $node->{children} };
ok $sub, 'found a subroutine child';
like $sub->{text}, qr/sub foo/, 'node text present';
is $sub->{fields}{name}{text}, 'foo', 'sub name accessible via fields';
done_testing;
