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
# handler reads a request param then calls run_cmd, which runs a dynamically-built command
# (a cross-sub taint path). direct reads a param AND runs a dynamic command in the SAME sub
# (a local hit). safe runs a command with constant/list args -> not dynamic -> not a target.
$d->child('lib/App.pm')->spew_utf8(<<'PL');
package App;
use v5.36;
sub handler ($self, $c) {
    my $name = $c->param('name');
    return run_cmd($name);
}
sub run_cmd ($arg) { system("echo $arg") }
sub direct ($self, $c) {
    my $cmd = $c->param('cmd');
    system("$cmd");
}
sub safe ($x) { system('ls', '-l') }
1;
PL

my $s = App::PerlGraph::Store->new(path => $d->child('.pcg/graph.db')->stringify); $s->init;
App::PerlGraph::Indexer->new(store => $s, root => "$d")->index_all;
my $q = App::PerlGraph::Query->new(store => $s);

my $r = $q->taint;
is $r->{sources}, 2, 'two user-input sources (both read ->param)';
is $r->{sinks},   2, 'two dynamic sinks (run_cmd and direct build their command from a variable)';
is scalar @{ $r->{paths} }, 2, 'two taint paths';

# the local (same-sub) hit ranks first and is flagged
my $first = $r->{paths}[0];
is $first->{local}, 1,                'the local source+sink-in-one-sub hit ranks first';
is $first->{path}[0], 'App::direct',  'the local hit names the sub';
is $first->{src_sub}, 'App::direct',  'src_sub is set';

# the cross-sub path shows the full call chain
my ($cross) = grep { !$_->{local} } @{ $r->{paths} };
is $cross->{path}, ['App::handler', 'App::run_cmd'], 'the cross-sub path shows source -> ... -> sink';
is $cross->{source}{kind}, 'request',  'the source is classified a request accessor';
is $cross->{source}{detail}, 'param',  'the accessor name is recorded';
ok +(grep { $_->{name} eq 'system' } @{ $cross->{sinks} }), 'the sink is the system() call';

# safe() (constant/list args) is NOT a dynamic sink, so it never appears
ok !(grep { $_->{sink_sub} && $_->{sink_sub} eq 'App::safe' } @{ $r->{paths} }), 'a constant-arg command is not a taint target';

# --- renderer ---
my $txt = App::PerlGraph::Format::taint($r);
like $txt, qr/Taint paths/,                    'format: header';
like $txt, qr/\*\*\[local\]\*\*/,              'format: flags the local hit';
like $txt, qr/`App::handler` -> `App::run_cmd`/, 'format: renders the call path';
like $txt, qr/REACHABILITY, not value-flow/,   'format: the honest caveat';
like App::PerlGraph::Format::taint({ paths => [], sinks => 0, sources => 0 }),
    qr/_no dynamic sinks found_/, 'format: clean-state (no dynamic sinks)';
like App::PerlGraph::Format::taint({ paths => [], sinks => 3, sources => 0 }),
    qr/no user-input source reaches/, 'format: dynamic sinks but no source reaching them';

# --- Query-level early returns (exercise $q->taint, not just the renderer) -------------
sub _taint_of ($code) {
    my $t = tempdir; $t->child('lib')->mkpath; $t->child('.pcg')->mkpath;
    $t->child('lib/Z.pm')->spew_utf8($code);
    my $st = App::PerlGraph::Store->new(path => $t->child('.pcg/graph.db')->stringify); $st->init;
    App::PerlGraph::Indexer->new(store => $st, root => "$t")->index_all;
    return App::PerlGraph::Query->new(store => $st)->taint;
}
my $nosink = _taint_of("package Z;\nsub f { system('ls', '-l') }\n1;\n");   # constant args -> no DYNAMIC sink
is $nosink->{sinks}, 0,           'Query: a codebase with no dynamic sink returns sinks => 0';
is scalar @{ $nosink->{paths} }, 0, 'Query: ...and no paths';
my $nosrc = _taint_of("package Z;\nuse v5.36;\nsub f (\$x) { system(\"\$x\") }\n1;\n");  # dynamic sink, no request source
is $nosrc->{sinks}, 1,            'Query: a dynamic sink with no user-input source still counts the sink';
is $nosrc->{sources}, 0,         'Query: ...but reports zero sources';
is scalar @{ $nosrc->{paths} }, 0, 'Query: ...and no taint paths';

done_testing;
