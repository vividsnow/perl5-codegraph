use v5.36;
use Test2::V0;
use App::PerlGraph::Installer;
use App::PerlGraph::MCP;
use Cpanel::JSON::XS qw(decode_json);
use Path::Tiny qw(tempdir path);

my $home = tempdir;
# Seed an existing sibling server + sibling permission; they must survive.
path($home)->child('.claude.json')->spew_utf8('{"mcpServers":{"other":{"command":"x"}},"numWarnings":3}');
path($home)->child('.claude')->mkpath;
path($home)->child('.claude/settings.json')->spew_utf8('{"permissions":{"allow":["Bash(ls:*)"]}}');

my $inst = App::PerlGraph::Installer->new(home => "$home", command => 'pcg');
$inst->install;

my $cfg = decode_json(path($home)->child('.claude.json')->slurp_raw);
is $cfg->{mcpServers}{pcg}{command}, 'pcg',              'pcg server registered';
is $cfg->{mcpServers}{pcg}{args}, ['serve', '--mcp'],    'args correct';
is $cfg->{mcpServers}{pcg}{type}, 'stdio',               'stdio type';
ok $cfg->{mcpServers}{other},                            'sibling server preserved';
is $cfg->{numWarnings}, 3,                               'sibling top-level key preserved';

my $set = decode_json(path($home)->child('.claude/settings.json')->slurp_raw);
ok( (grep { $_ eq 'mcp__pcg__pcg_callers' } @{ $set->{permissions}{allow} }), 'permission added' );
# allow-list is derived from MCP's tool list, so every exposed tool is covered
ok( (grep { $_ eq 'mcp__pcg__pcg_explore' } @{ $set->{permissions}{allow} }), 'pcg_explore allow-listed' );
ok( (grep { $_ eq 'mcp__pcg__pcg_unused' }  @{ $set->{permissions}{allow} }), 'pcg_unused allow-listed' );
is [ sort grep { /^mcp__pcg__/ } @{ $set->{permissions}{allow} } ],
   [ sort map { "mcp__pcg__$_" } App::PerlGraph::MCP->tool_names ],
   'allow-list exactly matches the exposed MCP tools';
ok( (grep { $_ eq 'Bash(ls:*)' }            @{ $set->{permissions}{allow} }), 'sibling permission preserved' );

# the agent skill is deployed
my $skill = path($home)->child('.claude/skills/perl-codegraph/SKILL.md');
ok $skill->exists, 'perl-codegraph skill deployed';
like $skill->slurp_utf8, qr/^name:\s*perl-codegraph/m, 'skill has the auto-trigger frontmatter';
like $skill->slurp_utf8, qr/pcg_unresolved/,            'skill documents the resolve workflow';

# idempotent
$inst->install;
my $set2 = decode_json(path($home)->child('.claude/settings.json')->slurp_raw);
is scalar(grep { $_ eq 'mcp__pcg__pcg_callers' } @{ $set2->{permissions}{allow} }), 1,
    'no duplicate permission on re-install';

# uninstall removes only pcg, keeps siblings
$inst->uninstall;
my $cfg3 = decode_json(path($home)->child('.claude.json')->slurp_raw);
ok !$cfg3->{mcpServers}{pcg},  'pcg server removed';
ok $cfg3->{mcpServers}{other}, 'sibling server still present';
my $set3 = decode_json(path($home)->child('.claude/settings.json')->slurp_raw);
ok !(grep { /^mcp__pcg__/ } @{ $set3->{permissions}{allow} }), 'pcg permissions removed';
ok( (grep { $_ eq 'Bash(ls:*)' } @{ $set3->{permissions}{allow} }), 'sibling permission kept' );
ok !path($home)->child('.claude/skills/perl-codegraph')->exists, 'uninstall removes the skill';

# uninstall on a pristine home must not materialize empty config files
my $home2 = tempdir;
App::PerlGraph::Installer->new(home => "$home2")->uninstall;
ok !path($home2)->child('.claude.json')->exists, 'uninstall creates no .claude.json when none existed';

# a FRESH home (no pre-existing config at all) installs cleanly, materializing both files
my $home3 = tempdir;
App::PerlGraph::Installer->new(home => "$home3", command => 'pcg')->install;
ok path($home3)->child('.claude.json')->exists,                            'fresh install creates .claude.json';
ok path($home3)->child('.claude/settings.json')->exists,                   'fresh install creates settings.json';
ok path($home3)->child('.claude/skills/perl-codegraph/SKILL.md')->exists,  'fresh install deploys the skill';
is decode_json(path($home3)->child('.claude.json')->slurp_raw)->{mcpServers}{pcg}{command}, 'pcg',
   'fresh install registers pcg';

# a malformed config is reported clearly and left UNTOUCHED (not a raw JSON exception, not clobbered)
my $home4 = tempdir;
path($home4)->child('.claude.json')->spew_raw('{ bad json,,');
like dies { App::PerlGraph::Installer->new(home => "$home4", command => 'pcg')->install },
     qr/cannot parse.*\.claude\.json/, 'a malformed config yields a clear error, not a raw exception';
like path($home4)->child('.claude.json')->slurp_raw, qr/bad json/, '... and the malformed file is left untouched';

done_testing;
