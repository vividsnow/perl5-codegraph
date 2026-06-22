use v5.36;
use Test2::V0;
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;

my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
$s->insert_node({ id => 'p', kind => 'package', name => 'P', qualified_name => 'P', file_path => 'f', start_line => 1 });
# a documented public function (has a POD docstring)
$s->insert_node({ id => 'd', kind => 'function', name => 'documented', qualified_name => 'P::documented',
    file_path => 'f', start_line => 2, visibility => 'public', docstring => 'Does a thing.' });
# an undocumented public function (no docstring)
$s->insert_node({ id => 'u', kind => 'function', name => 'plain', qualified_name => 'P::plain',
    file_path => 'f', start_line => 4, visibility => 'public' });
# a documented-with-only-whitespace function -> still undocumented
$s->insert_node({ id => 'w', kind => 'method', name => 'blanky', qualified_name => 'P::blanky',
    file_path => 'f', start_line => 6, visibility => 'public', docstring => "   \n  " });
# a private sub -> not public API, excluded regardless of docs
$s->insert_node({ id => 'x', kind => 'function', name => '_priv', qualified_name => 'P::_priv',
    file_path => 'f', start_line => 8, visibility => 'private' });
$s->insert_edge({ source => 'p', target => $_, kind => 'contains', provenance => 'static' }) for qw(d u w x);

my $q = App::PerlGraph::Query->new(store => $s);
my @undoc = $q->undocumented;
my %by = map { ($_->{qualified_name} => 1) } @undoc;
ok  $by{'P::plain'},      'an undocumented public sub is listed';
ok  $by{'P::blanky'},     'a whitespace-only docstring counts as undocumented';
ok !$by{'P::documented'}, 'a documented public sub is excluded';
ok !$by{'P::_priv'},      'a private sub is excluded (not public API)';

my $txt = App::PerlGraph::Format::undocumented(\@undoc);
like $txt, qr/Undocumented public API/, 'format: header';
like $txt, qr/`P::plain`/,              'format: lists the undocumented symbol';
like $txt, qr/2 undocumented public symbol/, 'format: the count';

# everything documented -> the clean "none" message
like App::PerlGraph::Format::undocumented([]), qr/every public symbol is documented/, 'format: clean state';

done_testing;
