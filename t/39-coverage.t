use v5.36;
use Test2::V0;
use Path::Tiny qw(tempdir);
use App::PerlGraph::Store;
use App::PerlGraph::Query;
use App::PerlGraph::Format;
use App::PerlGraph::Parser;
use App::PerlGraph::Extractor;
use App::PerlGraph::Indexer;
use App::PerlGraph::Source;
use App::PerlGraph::Installer;
use App::PerlGraph::CLI;

# ---------------------------------------------------------------------------
# Pure unit gaps (no parser needed)
# ---------------------------------------------------------------------------

# Store::upsert_edge provenance ladder: each rank upgrades, lower never downgrades,
# and a single edge is kept throughout.
{
    my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
    $s->insert_node({ id => 'a', kind => 'function', name => 'a', qualified_name => 'a', file_path => 'f' });
    $s->insert_node({ id => 'b', kind => 'function', name => 'b', qualified_name => 'b', file_path => 'f' });
    my $prov = sub { ($s->outgoing_edges('a', 'calls'))[0]{provenance} };
    $s->upsert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'heuristic' });
    is $prov->(), 'heuristic', 'upsert: first write keeps heuristic';
    $s->upsert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'static' });
    is $prov->(), 'static',    'upsert: static upgrades heuristic';
    $s->upsert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'framework' });
    is $prov->(), 'framework', 'upsert: framework upgrades static';
    $s->upsert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'optree' });
    is $prov->(), 'optree',    'upsert: optree upgrades framework';
    $s->upsert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'static' });
    is $prov->(), 'optree',    'upsert: a lower provenance never downgrades';
    is scalar($s->outgoing_edges('a', 'calls')), 1, 'upsert keeps exactly one edge';
}

# Format provenance tag: non-static provenance shows [tag]; static shows none.
{
    my $opt = { qualified_name => 'X::y', kind => 'function', file_path => 'f', start_line => 3, _provenance => 'optree' };
    like App::PerlGraph::Format::callers('X::z', [$opt]), qr/\[optree\]/, 'format tags non-static provenance';
    my $stat = { %$opt, _provenance => 'static' };
    unlike App::PerlGraph::Format::callers('X::z', [$stat]), qr/\[static\]/, 'format omits the tag for static';
}

# Query::impact across multiple hops (default depth), not just one.
{
    my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
    $s->insert_node({ id => $_, kind => 'function', name => $_, qualified_name => "Q::$_", file_path => 'f' }) for qw(a b c d);
    $s->insert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'static' });
    $s->insert_edge({ source => 'b', target => 'c', kind => 'calls', provenance => 'static' });
    $s->insert_edge({ source => 'c', target => 'd', kind => 'calls', provenance => 'static' });
    my %imp = map { ($_->{qualified_name} => 1) } App::PerlGraph::Query->new(store => $s)->impact('Q::d');
    ok $imp{'Q::a'} && $imp{'Q::b'} && $imp{'Q::c'}, 'impact returns transitive callers across 3 hops';
}

# Format::affected renders _none_ for an empty result.
like App::PerlGraph::Format::affected(['x.pm'], []), qr/_none_/, 'affected: empty result renders _none_';

# Query::graph emits edges in a stable, name-sorted order (diff-friendly export).
{
    my $s = App::PerlGraph::Store->new(path => ':memory:'); $s->init;
    $s->insert_node({ id => $_, kind => 'function', name => $_, qualified_name => "A::$_", file_path => 'f' }) for qw(a b c);
    $s->insert_edge({ source => 'c', target => 'a', kind => 'calls', provenance => 'static' });
    $s->insert_edge({ source => 'b', target => 'c', kind => 'calls', provenance => 'static' });
    $s->insert_edge({ source => 'a', target => 'b', kind => 'calls', provenance => 'static' });
    my $g = App::PerlGraph::Query->new(store => $s)->graph;
    my %nm = map { ($_->{id} => $_->{qualified_name}) } @{ $g->{nodes} };
    is [ map { "$nm{$_->{from}}->$nm{$_->{to}}" } @{ $g->{edges} } ],
       [ 'A::a->A::b', 'A::b->A::c', 'A::c->A::a' ],
       'graph edges are name-sorted (deterministic export output)';
}

# Source caps a long range at MAX_LINES with a trailing ellipsis.
{
    my $td = tempdir; my $f = $td->child('Big.pm');   # hold $td so it isn't reaped early
    $f->spew_utf8("package Big;\nsub f {\n" . ("  noop();\n" x 200) . "}\n1;\n");
    my $src = App::PerlGraph::Source::for_node({ file_path => "$f", start_line => 2, end_line => 210 }, '');
    like $src, qr/\.\.\.\s*\z/, 'source caps a long range and marks the truncation';
}

# Installer writes THROUGH a symlinked config instead of replacing the link.
SKIP: {
    my $home = tempdir;
    my $real = $home->child('real.json'); $real->spew_raw("{}\n");
    eval { symlink "$real", $home->child('.claude.json')->stringify; 1 };
    skip 'symlink unsupported here', 2 unless -l $home->child('.claude.json');
    App::PerlGraph::Installer->new(home => "$home")->install;
    ok -l $home->child('.claude.json'),    'install keeps the config symlink intact';
    like $real->slurp_raw, qr/mcpServers/, 'install wrote through to the real file';
}

# CLI: unknown command -> usage (exit 2); install/uninstall wrappers exit 0.
{ open my $fh, '>', \my $e; local *STDERR = $fh;
  is App::PerlGraph::CLI->run('notacommand'), 2, 'unknown command returns usage (2)'; }
{
    no warnings 'redefine';
    local *App::PerlGraph::Installer::install   = sub { $_[0] };
    local *App::PerlGraph::Installer::uninstall = sub { $_[0] };
    open my $fh, '>', \my $o; local *STDOUT = $fh;
    is App::PerlGraph::CLI->run('install'),   0, 'cli install wrapper exits 0';
    is App::PerlGraph::CLI->run('uninstall'), 0, 'cli uninstall wrapper exits 0';
    like $o, qr/Registered.*Removed/s,           'install/uninstall print confirmations';
}

# ---------------------------------------------------------------------------
# Parser-dependent gaps (CLI end to end + extraction edge cases)
# ---------------------------------------------------------------------------
my $have_grammar = eval { App::PerlGraph::Parser->new->parse_string("1;\n"); 1 };
if ($have_grammar) {
    my $parser = App::PerlGraph::Parser->new;

    # `require Foo::Bar;` emits an imports edge (only `use` was covered before).
    {
        my $out = App::PerlGraph::Extractor->new(file_path => 'x.pm')->extract($parser->parse_string("package X;\nrequire Foo::Bar;\n"));
        ok +(grep { $_->{kind} eq 'imports' && (($_->{metadata} || {})->{module} // '') eq 'Foo::Bar' } @{ $out->{edges} }),
            'require Foo::Bar emits an imports edge';
    }

    # `\&name` emits a `references` ref (the dead-code/callers machinery depends on it).
    {
        my $out = App::PerlGraph::Extractor->new(file_path => 'p.pm')->extract($parser->parse_string("package P;\nsub a { my \$r = \\&helper }\nsub helper { 1 }\n"));
        my ($ref) = grep { ($_->{reference_name} // '') eq 'helper' } @{ $out->{refs} };
        ok $ref, '\&name emits a ref';
        is $ref->{reference_kind}, 'references', 'refgen ref kind is `references`, not a call';
    }

    # CLI commands driven through run() (arg-extraction + _store glue).
    my $dir = tempdir; $dir->child('lib')->mkpath;
    $dir->child('lib/A.pm')->spew_utf8("package A;\nsub run { B::help() }\nsub other { run() }\n1;\n");
    $dir->child('lib/B.pm')->spew_utf8("package B;\nsub help { 1 }\n1;\n");
    $dir->child('t')->mkpath;
    $dir->child('t/a.t')->spew_utf8("use A;\nA::run();\n");   # a test that exercises the A->B chain
    my $cap = sub ($code) { open my $fh, '>', \my $o; local *STDOUT = $fh; my $rc = $code->(); return ($rc, $o // '') };

    my ($irc) = $cap->(sub { App::PerlGraph::CLI->run('index', "$dir") });
    is $irc, 0, 'cli index exits 0';

    my ($src, $so) = $cap->(sub { App::PerlGraph::CLI->run('status', "$dir") });
    is $src, 0, 'cli status exits 0';
    like $so, qr/nodes=\d+ edges=\d+/, 'cli status reports counts';

    my ($yrc, $syo) = $cap->(sub { App::PerlGraph::CLI->run('sync', "$dir") });
    is $yrc, 0, 'cli sync exits 0';
    like $syo, qr/synced/, 'cli sync reports';

    like +($cap->(sub { App::PerlGraph::CLI->run('search', 'help', "$dir") }))[1],         qr/B::help/, 'cli search';
    like +($cap->(sub { App::PerlGraph::CLI->run('node', 'A::run', "$dir") }))[1],          qr/A::run/,  'cli node';
    like +($cap->(sub { App::PerlGraph::CLI->run('explore', 'run', "$dir") }))[1],          qr/A::run/,  'cli explore';
    like +($cap->(sub { App::PerlGraph::CLI->run('callers', 'A::run', "$dir") }))[1],       qr/A::other/,'cli callers';
    like +($cap->(sub { App::PerlGraph::CLI->run('callees', 'A::run', "$dir") }))[1],       qr/B::help/, 'cli callees';
    like +($cap->(sub { App::PerlGraph::CLI->run('impact', 'B::help', "$dir") }))[1],       qr/A::run/,  'cli impact (transitive)';

    # affected: changing lib/B.pm affects lib/A.pm (A::run calls B::help); via --path + positional and via --stdin
    like +($cap->(sub { App::PerlGraph::CLI->run('affected', '--path', "$dir", 'lib/B.pm') }))[1],
        qr/A\.pm/, 'cli affected (--path + positional)';
    {
        open my $in, '<', \"lib/B.pm\n"; local *STDIN = $in;
        like +($cap->(sub { App::PerlGraph::CLI->run('affected', '--stdin', '--path', "$dir") }))[1],
            qr/A\.pm/, 'cli affected (--stdin)';
    }
    like +($cap->(sub { App::PerlGraph::CLI->run('affected', '--tests', '--path', "$dir", 'lib/B.pm') }))[1],
        qr/a\.t/, 'cli affected --tests restricts to test files';

    # the unknown-flag footgun is fixed: a mistyped flag is a usage error, not the root.
    { open my $fh, '>', \my $e; local *STDERR = $fh;
      is App::PerlGraph::CLI->run('index', '--runtim', "$dir"), 2, 'cli index rejects an unknown flag (no stray dir)';
      is App::PerlGraph::CLI->run('sync',  '--bogus',  "$dir"), 2, 'cli sync rejects an unknown flag'; }
    ok !-d "$dir/--runtim", 'a mistyped flag did not create a stray junk directory';

    # the same guard now also protects export/unused/affected.
    { open my $fh, '>', \my $e; local *STDERR = $fh;
      is App::PerlGraph::CLI->run('export', '--badflag', "$dir"),                     2, 'cli export rejects an unknown flag';
      is App::PerlGraph::CLI->run('unused', '--al', "$dir"),                          2, 'cli unused rejects a typo (--al)';
      is App::PerlGraph::CLI->run('affected', '--tset', 'lib/A.pm', '--path', "$dir"), 2, 'cli affected rejects a typo (--tset)'; }
    ok !-d "$dir/--badflag", 'an export typo created no stray directory';

    # `pcg serve` builds the query and invokes MCP->run (mocked so we don't block on stdin).
    { no warnings 'redefine'; my $ran = 0;
      local *App::PerlGraph::MCP::run = sub { $ran++ };
      App::PerlGraph::CLI->run('serve', '--mcp', "$dir");
      is $ran, 1, 'cli serve invokes MCP->run'; }

    # a file that vanished mid-scan is skipped, not fatal (watch/sync robustness).
    my $idx = App::PerlGraph::Indexer->new(store => App::PerlGraph::Store->new(path => ':memory:'), root => "$dir");
    is $idx->_read("$dir/does-not-exist.pm"),       undef, '_read returns undef for a vanished file (ENOENT)';
    is $idx->_index_file("$dir/does-not-exist.pm"), 0,     '_index_file skips a vanished file';

    # bin/pcg encodes UTF-8 output (the binmode lives in the script, not CLI::run,
    # so the in-memory test-capture idiom keeps working). Drive the real script.
    SKIP: {
        require Encode;
        my $u = tempdir; $u->child('lib')->mkpath;
        $u->child('lib/U.pm')->spew_utf8("package U;\nsub g { \"caf\x{e9} r\x{e9}sum\x{e9}\" }\n1;\n");
        skip 'subprocess pcg index failed', 2 unless system($^X, '-Ilib', 'bin/pcg', 'index', "$u") == 0;
        my $out  = qx{"$^X" -Ilib bin/pcg node U::g "$u" 2>&1};
        my $cafe = Encode::encode('UTF-8', "caf\x{e9} r\x{e9}sum\x{e9}");
        like   $out, qr/\Q$cafe\E/,      'bin/pcg renders UTF-8 source bytes (single-encoded)';
        unlike $out, qr/Wide character/, 'bin/pcg emits no wide-character warning';
    }
}
else { note 'skipping parser-dependent coverage: grammar not built' }

done_testing;
