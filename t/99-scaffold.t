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
$d->child('lib/Geo.pm')->spew_utf8(<<'PL');
package Geo;
use v5.36;
sub area  ($w, $h)       { $w * $h }
sub scale ($self, $factor) { $self }
sub none                 { 1 }
1;
PL
my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $q = App::PerlGraph::Query->new(store => $s);

# a plain function: POD + test use the bare-call shape with one placeholder per param
my $fn = App::PerlGraph::Format::scaffold($q->scaffold('Geo::area'));
like $fn, qr/Scaffold for `Geo::area`/,             'header names the sub';
like $fn, qr/=head2 area\(\$w, \$h\)/,               'POD skeleton lists the params';
like $fn, qr/use Geo;/,                              'test skeleton loads the package';
like $fn, qr/Geo::area\(TODO_w, TODO_h\)/,           'test calls it with a placeholder per parameter';
like $fn, qr/done_testing/,                          'test skeleton is runnable boilerplate';

# a method-shaped sub ($self first): the invocant is dropped and the call uses $obj->
my $m = App::PerlGraph::Format::scaffold($q->scaffold('Geo::scale'));
like $m, qr/=head2 \$obj->scale\(\$factor\)/,        'method POD drops the invocant and uses $obj->';
like $m, qr/my \$obj = Geo->new/,                    'method test constructs an instance';
like $m, qr/\$obj->scale\(TODO_factor\)/,            'method test calls via the instance, invocant dropped';

# no params -> empty arg list, no crash
like App::PerlGraph::Format::scaffold($q->scaffold('Geo::none')), qr/=head2 none\(\)/, 'a no-arg sub scaffolds an empty signature';

# unknown symbol errors
like App::PerlGraph::Format::scaffold($q->scaffold('No::Such')), qr/no function.method/, 'an unknown symbol errors';

done_testing;
