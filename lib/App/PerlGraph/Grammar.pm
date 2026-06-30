package App::PerlGraph::Grammar;
use v5.36;
our $VERSION = q{0.072};
use Exporter 'import';

# Node-type names — verified against tree-sitter-perl v1.1.2 (see docs/grammar-ground-truth.md).
use constant {
    NODE_ROOT           => 'source_file',
    NODE_PACKAGE        => 'package_statement',
    NODE_CLASS          => 'class_statement',          # native `class NAME {...}` (perl 5.38+ / Object::Pad)
    NODE_ROLE           => 'role_statement',           # Object::Pad `role NAME {...}` (class-like; methods compose in)
    NODE_SUB            => 'subroutine_declaration_statement',
    NODE_METHOD_DECL    => 'method_declaration_statement',
    NODE_USE            => 'use_statement',
    NODE_REQUIRE        => 'require_expression',
    NODE_CALL           => 'function_call_expression',
    NODE_CALL_AMBIG     => 'ambiguous_function_call_expression',
    NODE_CALL_OP        => 'func0op_call_expression',
    NODE_METHOD_CALL    => 'method_call_expression',
    NODE_ASSIGN         => 'assignment_expression',
    NODE_VAR_DECL       => 'variable_declaration',
    NODE_FIELD          => 'field',                    # the `field` keyword leading a class field var-decl
    NODE_QW             => 'quoted_word_list',
    NODE_BLOCK          => 'block',
    NODE_EXPR_STMT      => 'expression_statement',
    # name-bearing leaf nodes (read ->text)
    NODE_PACKAGE_NAME   => 'package',
    NODE_BAREWORD       => 'bareword',
    NODE_FUNCTION       => 'function',
    NODE_METHOD         => 'method',
    NODE_VARNAME        => 'varname',
    NODE_STRING_CONTENT => 'string_content',
    # framework / attribute nodes (Layer 3)
    NODE_ANON_SUB       => 'anonymous_subroutine_expression',
    NODE_ATTRLIST       => 'attrlist',
    NODE_ATTRIBUTE      => 'attribute',
    NODE_ATTR_NAME      => 'attribute_name',
    NODE_ATTR_VALUE     => 'attribute_value',
    NODE_STRING_LIT     => 'string_literal',
    NODE_INTERP_STRING  => 'interpolated_string_literal',
    NODE_LIST_EXPR      => 'list_expression',
    NODE_REFGEN         => 'refgen_expression',   # \&foo  (take a code ref)
    # field names
    F_NAME      => 'name',
    F_MODULE    => 'module',
    F_FUNCTION  => 'function',
    F_METHOD    => 'method',
    F_INVOCANT  => 'invocant',
    F_LEFT      => 'left',
    F_RIGHT     => 'right',
    F_BODY      => 'body',
    F_VARIABLE  => 'variable',
    F_CONTENT   => 'content',
    F_ARGUMENTS => 'arguments',
    F_ATTRIBUTES => 'attributes',
    F_VALUE      => 'value',
};

# All three call-expression node types share a `function` field.
use constant CALL_TYPES => [qw(
    function_call_expression ambiguous_function_call_expression func0op_call_expression
)];

our @EXPORT_OK = qw(
    NODE_ROOT NODE_PACKAGE NODE_CLASS NODE_ROLE NODE_SUB NODE_METHOD_DECL NODE_USE NODE_REQUIRE
    NODE_CALL NODE_CALL_AMBIG NODE_CALL_OP NODE_METHOD_CALL NODE_ASSIGN
    NODE_VAR_DECL NODE_FIELD NODE_QW NODE_BLOCK NODE_EXPR_STMT
    NODE_PACKAGE_NAME NODE_BAREWORD NODE_FUNCTION NODE_METHOD NODE_VARNAME NODE_STRING_CONTENT
    NODE_ANON_SUB NODE_ATTRLIST NODE_ATTRIBUTE NODE_ATTR_NAME NODE_ATTR_VALUE NODE_STRING_LIT NODE_INTERP_STRING NODE_LIST_EXPR NODE_REFGEN
    F_NAME F_MODULE F_FUNCTION F_METHOD F_INVOCANT F_LEFT F_RIGHT F_BODY F_VARIABLE F_CONTENT F_ARGUMENTS F_ATTRIBUTES F_VALUE
    CALL_TYPES
);
our %EXPORT_TAGS = (all => \@EXPORT_OK);
1;

__END__

=head1 NAME

App::PerlGraph::Grammar - tree-sitter-perl node-type and field vocabulary

=head1 DESCRIPTION

Symbolic constants for the tree-sitter-perl node types and fields the extractor matches.

This is an internal module of L<App::PerlGraph>; see L<App::PerlGraph> and the
C<pcg> command for the public interface.

=head1 AUTHOR

vividsnow E<lt>vividsnow@pm.meE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2026 by vividsnow. This library is free software; you may
redistribute and/or modify it under the same terms as Perl itself.

=cut
