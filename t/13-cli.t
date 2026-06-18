use v5.36;
use Test2::V0;
use App::PerlGraph::Parser;
my $parser = eval { App::PerlGraph::Parser->new } or skip_all "parser unavailable: $@";
eval { $parser->parse_string("1;\n") } or skip_all "grammar not built: $@";

use Path::Tiny qw(tempdir);
use App::PerlGraph::CLI;

my $dir = tempdir;
$dir->child('lib')->mkpath;
$dir->child('lib/My.pm')->spew_utf8("package My;\nsub hi { greet() }\nsub greet { 1 }\n1;\n");

my $rc = App::PerlGraph::CLI->run('index', "$dir");
is $rc, 0, 'index returns 0';

my $out = '';
{
    open my $fh, '>', \$out;
    local *STDOUT = $fh;
    App::PerlGraph::CLI->run('callers', 'My::greet', "$dir");
}
like $out, qr/My::hi/, 'pcg callers finds My::hi';
done_testing;
