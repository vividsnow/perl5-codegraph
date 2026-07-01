use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Parser;
use App::PerlGraph::Store;
use App::PerlGraph::Indexer;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::Extractor;

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
like $txt, qr/\[value-flow\].*strongest/s,     'format: the caveat ranks [value-flow] as the strongest tier (not [local])';
like $txt, qr/REACHABILITY only/,              'format: an untagged cross-sub path is called reachability-only';
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

# --- external (non-web) sources: $ENV / @ARGV / STDIN -> a dynamic sink (CLI / env injection) ---
my $env = _taint_of("package Z;\nuse v5.36;\nsub run { my \$c = \$ENV{CMD}; system(\"echo \$c\") }\n1;\n");
is scalar @{ $env->{paths} }, 1,         'Query: a sub reading $ENV that runs a dynamic command is a taint path';
is $env->{paths}[0]{source}{kind}, 'external', 'Query: $ENV is classified an external source';
is $env->{paths}[0]{source}{detail}, '$ENV',   'Query: the source detail names $ENV';
ok $env->{paths}[0]{local},              'Query: read + used in one sub is a [local] hit';
my $argv = _taint_of("package Z;\nuse v5.36;\nsub run { my \$f = \$ARGV[0]; system(\"cat \$f\") }\n1;\n");
is $argv->{paths}[0]{source}{detail}, '@ARGV', 'Query: \$ARGV[0] / \@ARGV is detected as an external source';
my $stdin = _taint_of("package Z;\nuse v5.36;\nsub run { my \$l = <STDIN>; system(\"grep \$l\") }\n1;\n");
is $stdin->{paths}[0]{source}{detail}, 'STDIN', 'Query: <STDIN> is detected as an external source';

# --- intra-procedural VALUE-FLOW: confirm the tainted value reaches the sink ARGUMENT ----
my $vf = _taint_of("package Z;\nuse v5.36;\nsub run { my \$c = \$ENV{CMD}; system(\"echo \$c\") }\n1;\n");
ok $vf->{paths}[0]{value_flow}, 'Query: $ENV value assigned then interpolated into system() is value-flow-confirmed';
ok $vf->{paths}[0]{local},      'Query: ...and still a local hit';
# co-located but NOT value-flow: reads $ENV, but the sink interpolates an UNTAINTED var
my $co = _taint_of("package Z;\nuse v5.36;\nsub cfg { '/t' }\nsub run { my \$u = \$ENV{U}; my \$d = cfg(); system(\"ls \$d\") }\n1;\n");
my ($corun) = grep { $_->{src_sub} =~ /::run/ } @{ $co->{paths} };
ok $corun && $corun->{local},        'Query: source + sink in one sub is a local hit';
ok $corun && !$corun->{value_flow},  'Query: ...but NOT value-flow when the sink arg is an untainted var (co-located only)';
# the source interpolated DIRECTLY into the sink (hash-element interp is a dynamic sink + value-flow)
my $di = _taint_of("package Z;\nuse v5.36;\nsub run { system(\"run \$ENV{X}\") }\n1;\n");
ok $di->{paths}[0] && $di->{paths}[0]{value_flow}, 'Query: $ENV{X} interpolated straight into system() is a dynamic sink AND value-flow';
# taint propagates through a LIST assignment whose RHS holds a tainted var, even though one LHS
# could already be tainted -- the fixed point must not bail on the whole multi-target assignment.
my $li = _taint_of("package Z;\nuse v5.36;\nsub run { my \$c = \$ENV{CMD}; my (\$a, \$b) = split(/ /, \$c); system(\"go \$a\") }\n1;\n");
ok $li->{paths}[0] && $li->{paths}[0]{value_flow}, 'Query: $ENV -> $c -> ($a,$b)=split(...$c) -> system($a) is value-flow (list-assignment propagation)';
# a source named only in a COMMENT is not a real read -- must not flag the sub as a taint source
my $cmt = _taint_of("package Z;\nuse v5.36;\nsub run (\$x) {\n    # historically read \$ENV{PATH} here\n    system(\"\$x\");\n}\n1;\n");
is $cmt->{sources}, 0, 'Query: a $ENV mentioned only in a full-line comment is NOT counted as a taint source';
my $icmt = _taint_of("package Z;\nuse v5.36;\nsub run (\$x) {\n    system(\"\$x\");  # avoids \$ENV{HOME} on sandboxed runs\n}\n1;\n");
is $icmt->{sources}, 0, 'Query: a $ENV in an INLINE (trailing) comment is NOT counted as a taint source either';

# --- CROSS-SUB value-flow: VERIFIED inter-procedural (the tainted value propagates arg->param into the sink) ---
my $xs = _taint_of("package Z;\nuse v5.36;\nsub handler { my \$x = \$ENV{CMD}; return run(\$x) }\nsub run (\$cmd) { system(\"echo \$cmd\") }\n1;\n");
my ($xp) = grep { ($_->{src_sub} // '') =~ /handler/ } @{ $xs->{paths} };
ok $xp && $xp->{param_flow},   'Query: source -> run($x), run($cmd) sinks $cmd -> VERIFIED [cross-sub]';
ok $xp && !$xp->{value_flow},  'Query: ...NOT intra-sub value-flow (the sink is in a different sub)';
ok $xp && !$xp->{local},       'Query: ...and not local';
# MULTI-HOP: source -> step($x) -> run($v) -> sink, verified through two calls
my $mh = _taint_of("package Z;\nuse v5.36;\nsub h { my \$x = \$ENV{C}; return step(\$x) }\nsub step (\$v) { return run(\$v) }\nsub run (\$cmd) { system(\"echo \$cmd\") }\n1;\n");
my ($mp) = grep { ($_->{src_sub} // '') =~ /::h\z/ } @{ $mh->{paths} };
ok $mp && $mp->{param_flow}, 'Query: multi-hop source -> step -> run is verified [cross-sub]';
# a helper whose dynamic sink is fed by a CONSTANT (not its parameter) is only reachability, not verified
my $ns = _taint_of("package Z;\nuse v5.36;\nsub handler { my \$x = \$ENV{CMD}; return logit(\$x) }\nsub logit (\$m) { my \$c = '/tmp/x'; system(\"touch \$c\") }\n1;\n");
my ($np) = grep { ($_->{src_sub} // '') =~ /handler/ } @{ $ns->{paths} };
ok $np && !$np->{param_flow}, 'Query: a helper whose sink is fed by a CONSTANT (not its param) is untagged, not [cross-sub]';
# POSITION precision: the tainted value is passed at the arg position of a param that does NOT reach the sink
my $pp = _taint_of("package Z;\nuse v5.36;\nsub c { my \$z = \$ENV{Z}; return two(\$z, 'k') }\nsub two (\$val, \$key) { system(\"echo \$key\") }\n1;\n");
my ($pq) = grep { ($_->{src_sub} // '') =~ /::c\z/ } @{ $pp->{paths} };
ok $pq && !$pq->{param_flow}, 'Query: tainted arg maps to $val (param 1) but the sink is fed by $key (param 2) -> NOT verified';
# QUOTE-AWARE position: a comma INSIDE a quoted argument must not be read as an argument separator, or
# the tainted arg's position shifts and the cross-sub flow is missed. Here `$x` is the 2nd arg (after the
# SQL-ish string literal that itself contains a comma) and must map to `$cmd` (param 2) -> still verified.
my $qa = _taint_of("package Z;\nuse v5.36;\nsub h { my \$x = \$ENV{C}; return run(\"a, b, c\", \$x) }\nsub run (\$lit, \$cmd) { system(\"echo \$cmd\") }\n1;\n");
my ($qp) = grep { ($_->{src_sub} // '') =~ /::h\z/ } @{ $qa->{paths} };
ok $qp && $qp->{param_flow}, 'Query: a comma inside a quoted arg does not shift the tainted arg position (still verified [cross-sub])';

# --- _split_args UNIT: the positional splitter that feeds taint_out arg positions must be bracket-,
# quote-, AND backslash-parity aware (a mis-split shifts every downstream arg position) --------------
{
    my $sp = \&App::PerlGraph::Extractor::_split_args;
    is [ $sp->(q{$a, $b}) ],          ['$a', ' $b'],          '_split_args: plain top-level comma splits';
    is [ $sp->(q{"a, b", $x}) ],      ['"a, b"', ' $x'],      '_split_args: comma inside a double-quoted string is not a separator';
    is [ $sp->(q{'a, b', $x}) ],      [q{'a, b'}, ' $x'],     '_split_args: comma inside a single-quoted string is not a separator';
    is [ $sp->(q{f(1, 2), $x}) ],     ['f(1, 2)', ' $x'],     '_split_args: comma inside brackets is not a separator';
    is [ $sp->(qq{"a\\", b", \$x}) ], [qq{"a\\", b"}, ' $x'], '_split_args: an escaped quote (odd backslash) does not end the string';
    is [ $sp->(qq{"x\\\\", \$y}) ],   [qq{"x\\\\"}, ' $y'],   '_split_args: an even backslash run before a quote DOES close (parity)';
}

done_testing;
