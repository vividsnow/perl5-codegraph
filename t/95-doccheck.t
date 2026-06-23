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

my $d = tempdir; $d->child('lib')->mkpath; $d->child('.pcg')->mkpath;

# Base class with a real method, documented and inherited by Child.
$d->child('lib/Base.pm')->spew_utf8(<<'PL');
package Base;
use v5.36;
sub shared ($self) { 1 }
1;
PL

# Child: documents one real method, two stale ones (no sub), one inherited (Base::shared),
# and a prose section heading -- only the two stale entries should be flagged.
$d->child('lib/Child.pm')->spew_utf8(<<'PL');
package Child;
use v5.36;
use constant LIMIT => 10;
use parent -norequire, 'Base';
sub query ($self, $sql) { ... }
1;
=head1 METHODS
=head2 query($sql)
A real method.
=head2 LIMIT()
A documented constant -- must NOT be flagged.
=head2 shared()
Inherited from Base -- must NOT be flagged.
=head2 disconnect()
STALE -- no such sub.
=item C<< $obj->fetch($row) >>
STALE -- no such sub.
=head2 Configuration
A prose section -- must NOT be flagged.
=head2 new()
A constructor (auto-provided) -- must NOT be flagged.
=cut
PL

my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $q = App::PerlGraph::Query->new(store => $s);

my $f = $q->doccheck("$d");
my %name = map { ($_->{name} => $_) } @$f;
is scalar @$f, 2, 'exactly the two stale POD entries are flagged';
ok $name{disconnect}, 'a `=head2 disconnect()` for a removed method is flagged';
ok $name{fetch},      'an `=item C<< $obj->fetch >>` for a removed method is flagged';
ok !$name{shared},        'an INHERITED method (Base::shared) documented in the subclass is not flagged';
ok !$name{query},         'a real method is not flagged';
ok !$name{Configuration}, 'a prose section heading (no call form) is not flagged';
ok !$name{new},           'an auto-provided constructor (new) is not flagged';
ok !$name{LIMIT},         'a documented `use constant` is not flagged (constants are public API)';
is $name{disconnect}{file}, 'lib/Child.pm', 'the finding carries the documenting file';

my $txt = App::PerlGraph::Format::doccheck($f);
like $txt, qr/Stale POD/,                      'renders a header';
like $txt, qr/`disconnect`.*no such sub/,      'names the stale entry';
like App::PerlGraph::Format::doccheck([]), qr/_none found_/, 'empty state renders cleanly';

done_testing;
