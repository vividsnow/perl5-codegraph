use v5.36;
use Test2::V0;
use App::PerlGraph::Model qw(node_id package_of qualify is_builtin);

is package_of('Foo::Bar::baz'), 'Foo::Bar', 'package_of strips last segment';
is package_of('main_sub'),       'main',     'unqualified -> main';
is qualify('Foo::Bar', 'baz'),   'Foo::Bar::baz', 'qualify joins';

ok is_builtin('print'), 'print is a builtin';
ok !is_builtin('make'), 'make is not a builtin';

my $a = node_id({ kind => 'function', qualified_name => 'Foo::baz', file_path => 'lib/Foo.pm', start_line => 3 });
my $b = node_id({ kind => 'function', qualified_name => 'Foo::baz', file_path => 'lib/Foo.pm', start_line => 3 });
is $a, $b, 'node_id is deterministic';
like $a, qr/^[0-9a-f]{40}$/, 'node_id is a sha1 hex';
done_testing;
