package GraphQL::Execution;

use 5.014;
use strict;
use warnings;
use Return::Type;
use Types::Standard -all;
use Types::TypeTiny -all;
use GraphQL::Type::Library -all;
use Function::Parameters;
use GraphQL::Language::Parser qw(parse);
use GraphQL::Error;
use JSON::MaybeXS;
use GraphQL::Debug qw(_debug);
use GraphQL::Introspection qw(
  $SCHEMA_META_FIELD_DEF $TYPE_META_FIELD_DEF $TYPE_NAME_META_FIELD_DEF
);
use GraphQL::Directive;
use GraphQL::Schema qw(lookup_type);
use Exporter 'import';

=head1 NAME

GraphQL::Execution - Execute GraphQL queries

=cut

our @EXPORT_OK = qw(
  execute
);
our $VERSION = '0.02';

my $JSON = JSON::MaybeXS->new->allow_nonref;
use constant DEBUG => $ENV{GRAPHQL_DEBUG}; # "DEBUG and" gets optimised out if false

=head1 SYNOPSIS

  use GraphQL::Execution qw(execute);
  my $result = execute($schema, $doc, $root_value);

=head1 DESCRIPTION

Executes a GraphQL query, returns results.

=head1 METHODS

=head2 execute

  my $result = execute(
    $schema,
    $doc, # can also be AST
    $root_value,
    $context_value,
    $variable_values,
    $operation_name,
    $field_resolver,
  );

=cut

fun execute(
  (InstanceOf['GraphQL::Schema']) $schema,
  Str | ArrayRef[HashRef] $doc,
  Any $root_value = undef,
  Any $context_value = undef,
  Maybe[HashRef] $variable_values = undef,
  Maybe[Str] $operation_name = undef,
  Maybe[CodeLike] $field_resolver = undef,
) :ReturnType(HashRef) {
  my $context = eval {
    my $ast = ref($doc) ? $doc : parse($doc);
    _build_context(
      $schema,
      $ast,
      $root_value,
      $context_value,
      $variable_values,
      $operation_name,
      $field_resolver,
    );
  };
  return { errors => [ GraphQL::Error->coerce($@)->to_json ] } if $@;
  (my $result, $context) = eval {
    _execute_operation(
      $context,
      $context->{operation},
      $root_value,
    );
  };
  $context = _context_error($context, GraphQL::Error->coerce($@)) if $@;
  my $wrapped = { data => $result };
  if (@{ $context->{errors} || [] }) {
    return { errors => [ map $_->to_json, @{$context->{errors}} ], %$wrapped };
  } else {
    return $wrapped;
  }
}

fun _context_error(
  HashRef $context,
  Any $error,
) :ReturnType(HashRef) {
  # like push but no mutation
  +{ %$context, errors => [ @{$context->{errors} || []}, $error ] };
}

fun _build_context(
  (InstanceOf['GraphQL::Schema']) $schema,
  ArrayRef[HashRef] $ast,
  Any $root_value,
  Any $context_value,
  Maybe[HashRef] $variable_values,
  Maybe[Str] $operation_name,
  Maybe[CodeLike] $field_resolver,
) :ReturnType(HashRef) {
  my %fragments = map {
    ($_->{name} => $_)
  } grep $_->{kind} eq 'fragment', @$ast;
  my @operations = grep $_->{kind} eq 'operation', @$ast;
  die "No operations supplied.\n" if !@operations;
  die "Can only execute document containing fragments or operations\n"
    if @$ast != keys(%fragments) + @operations;
  my $operation = _get_operation($operation_name, \@operations);
  {
    schema => $schema,
    fragments => \%fragments,
    root_value => $root_value,
    context_value => $context_value,
    operation => $operation,
    variable_values => _variables_apply_defaults(
      $schema,
      $operation->{variables} || {},
      $variable_values || {},
    ),
    field_resolver => $field_resolver || \&_default_field_resolver,
    errors => [],
  };
}

# takes each operation var: query q(a: String)
#  applies to it supplied variable from web request
#  if none, applies any defaults in the operation var: query q(a: String = "h")
#  converts with graphql_to_perl (which also validates) to Perl values
# return { varname => { value => ..., type => $type } }
fun _variables_apply_defaults(
  (InstanceOf['GraphQL::Schema']) $schema,
  HashRef $operation_variables,
  HashRef $variable_values,
) :ReturnType(HashRef) {
  my @bad = grep {
    ! lookup_type($operation_variables->{$_}, $schema->name2type)->DOES('GraphQL::Role::Input');
  } keys %$operation_variables;
  die "Variable '\$$bad[0]' is type '@{[
    lookup_type($operation_variables->{$bad[0]}, $schema->name2type)->to_string
  ]}' which cannot be used as an input type.\n" if @bad;
  +{ map {
    my $opvar = $operation_variables->{$_};
    my $opvar_type = lookup_type($opvar, $schema->name2type);
    my $parsed_value;
    my $maybe_value = $variable_values->{$_} // $opvar->{default_value};
    eval { $parsed_value = $opvar_type->graphql_to_perl($maybe_value) };
    if ($@) {
      my $error = $@;
      $error =~ s#\s+at.*line\s+\d+\.#.#;
      die "Variable '\$$_' got invalid value @{[$JSON->canonical->encode($maybe_value)]}.\n$error";
    }
    ($_ => { value => $parsed_value, type => $opvar_type })
  } keys %$operation_variables };
}

fun _get_operation(
  Maybe[Str] $operation_name,
  ArrayRef[HashRef] $operations,
) {
  DEBUG and _debug('_get_operation', @_);
  if (!$operation_name) {
    die "Must provide operation name if query contains multiple operations.\n"
      if @$operations > 1;
    return $operations->[0];
  }
  my @matching = grep $_->{name} eq $operation_name, @$operations;
  return $matching[0] if @matching == 1;
  die "No operations matching '$operation_name' found.\n";
}

fun _execute_operation(
  HashRef $context,
  HashRef $operation,
  Any $root_value,
) {
  my $op_type = $operation->{operationType} || 'query';
  my $type = $context->{schema}->$op_type;
  my ($fields) = $type->_collect_fields(
    $context,
    $operation->{selections},
    {},
    {},
  );
  DEBUG and _debug('_execute_operation(fields)', $fields, $root_value);
  my $path = [];
  my $execute = $op_type eq 'mutation'
    ? \&_execute_fields_serially : \&_execute_fields;
  (my $result, $context) = eval {
    $execute->($context, $type, $root_value, $path, $fields);
  };
  return ({}, _context_error($context, GraphQL::Error->coerce($@))) if $@;
  ($result, $context);
}

fun _execute_fields(
  HashRef $context,
  (InstanceOf['GraphQL::Type']) $parent_type,
  Any $root_value,
  ArrayRef $path,
  Map[StrNameValid,ArrayRef[HashRef]] $fields,
) :ReturnType(Map[StrNameValid,Any]) {
  my %results;
  DEBUG and _debug('_execute_fields', $parent_type->to_string, $fields, $root_value);
  map {
    my $result_name = $_;
    my $result;
    eval {
      my $nodes = $fields->{$result_name};
      my $field_node = $nodes->[0];
      my $field_name = $field_node->{name};
      DEBUG and _debug('_execute_fields(resolve)', $parent_type->to_string, $nodes, $root_value);
      my $field_def = _get_field_def($context->{schema}, $parent_type, $field_name);
      my $resolve = $field_def->{resolve} || $context->{field_resolver};
      my $info = _build_resolve_info(
        $context,
        $parent_type,
        $field_def,
        [ @$path, $result_name ],
        $nodes,
      );
      my $resolve_node = _build_resolve_node(
        $context,
        $field_def,
        $nodes,
        $resolve,
        $info,
      );
      if (!GraphQL::Error->is($resolve_node)) {
        $result = _resolve_field_value_or_error($resolve_node, $root_value);
      } else {
        $result = $resolve_node; # failed early
      }
      ($result, $context) = _complete_value_catching_error(
        $context,
        $field_def->{type},
        $nodes,
        $info,
        [ @$path, $result_name ],
        $result,
      );
      DEBUG and _debug('_execute_fields(complete)', $result);
    };
    if ($@) {
      $context = _context_error(
        $context,
        _located_error($@, $fields->{$result_name}, [ @$path, $result_name ])
      );
    } else {
      $results{$result_name} = $result;
      # TODO promise stuff
    }
  } keys %$fields; # TODO ordering of fields
  DEBUG and _debug('_execute_fields(done)', \%results);
  (\%results, $context);
}

fun _execute_fields_serially(
  HashRef $context,
  (InstanceOf['GraphQL::Type']) $parent_type,
  Any $root_value,
  ArrayRef $path,
  Map[StrNameValid,ArrayRef[HashRef]] $fields,
) {
  DEBUG and _debug('_execute_fields_serially', $parent_type->to_string, $fields, $root_value);
  # TODO implement
  goto &_execute_fields;
}

use constant FIELDNAME2SPECIAL => {
  map { ($_->{name} => $_) } $SCHEMA_META_FIELD_DEF, $TYPE_META_FIELD_DEF
};
fun _get_field_def(
  (InstanceOf['GraphQL::Schema']) $schema,
  (InstanceOf['GraphQL::Type']) $parent_type,
  StrNameValid $field_name,
) :ReturnType(HashRef) {
  return $TYPE_NAME_META_FIELD_DEF
    if $field_name eq $TYPE_NAME_META_FIELD_DEF->{name};
  return FIELDNAME2SPECIAL->{$field_name}
    if FIELDNAME2SPECIAL->{$field_name} and $parent_type == $schema->query;
  $parent_type->fields->{$field_name} //
    die GraphQL::Error->new(
      message => "No field @{[$parent_type->name]}.$field_name."
    );
}

# NB similar ordering as _execute_fields - graphql-js switches
fun _build_resolve_info(
  HashRef $context,
  (InstanceOf['GraphQL::Type']) $parent_type,
  HashRef $field_def,
  ArrayRef $path,
  ArrayRef[HashRef] $nodes,
) {
  {
    field_name => $nodes->[0]{name},
    field_nodes => $nodes,
    return_type => $field_def->{type},
    parent_type => $parent_type,
    path => $path,
    schema => $context->{schema},
    fragments => $context->{fragments},
    root_value => $context->{root_value},
    operation => $context->{operation},
    variable_values => $context->{variable_values},
  };
}

fun _build_resolve_node(
  HashRef $context,
  HashRef $field_def,
  ArrayRef[HashRef] $nodes,
  Maybe[CodeLike] $resolve,
  HashRef $info,
) {
  DEBUG and _debug('_build_resolve_node', $nodes, $field_def, eval { $JSON->encode($nodes->[0]) });
  my $args = eval {
    _get_argument_values($field_def, $nodes->[0], $context->{variable_values});
  };
  return GraphQL::Error->coerce($@) if $@;
  DEBUG and _debug("_build_resolve_node(args)", $args, eval { $JSON->encode($args) });
  {
    args => [ $args, $context->{context_value}, $info ],
    resolve => $resolve,
  };
}

fun _resolve_field_value_or_error(
  HashRef $resolve_node,
  Maybe[Any] $root_value,
) {
  DEBUG and _debug('_resolve_field_value_or_error', $resolve_node);
  my $result = eval {
    $resolve_node->{resolve}->($root_value, @{$resolve_node->{args}})
  };
  return GraphQL::Error->coerce($@) if $@;
  $result;
}

fun _complete_value_catching_error(
  HashRef $context,
  (InstanceOf['GraphQL::Type']) $return_type,
  ArrayRef[HashRef] $nodes,
  HashRef $info,
  ArrayRef $path,
  Any $result,
) {
  if ($return_type->isa('GraphQL::Type::NonNull')) {
    return _complete_value_with_located_error(@_);
  }
  my $result = eval {
    (my $completed, $context) = _complete_value_with_located_error(@_);
    # TODO promise stuff
    $completed;
  };
  return (undef, _context_error($context, GraphQL::Error->coerce($@))) if $@;
  ($result, $context);
}

fun _complete_value_with_located_error(
  HashRef $context,
  (InstanceOf['GraphQL::Type']) $return_type,
  ArrayRef[HashRef] $nodes,
  HashRef $info,
  ArrayRef $path,
  Any $result,
) {
  my $result = eval {
    (my $completed, $context) = _complete_value(@_);
    # TODO promise stuff
    $completed;
  };
  die _located_error($@, $nodes, $path) if $@;
  ($result, $context);
}

fun _complete_value(
  HashRef $context,
  (InstanceOf['GraphQL::Type']) $return_type,
  ArrayRef[HashRef] $nodes,
  HashRef $info,
  ArrayRef $path,
  Any $result,
) {
  DEBUG and _debug('_complete_value', $return_type->to_string, $path, $result);
  # TODO promise stuff
  die $result if GraphQL::Error->is($result);
  return ($result, $context) if !defined $result
    and !$return_type->isa('GraphQL::Type::NonNull');
  $return_type->_complete_value(
    $context,
    $nodes,
    $info,
    $path,
    $result,
  );
}

fun _located_error(
  Any $error,
  ArrayRef[HashRef] $nodes,
  ArrayRef $path,
) {
  GraphQL::Error->coerce($error)->but(
    locations => [ map $_->{location}, @$nodes ],
    path => $path,
  );
}

fun _get_argument_values(
  (HashRef | InstanceOf['GraphQL::Directive']) $def,
  HashRef $node,
  Maybe[HashRef] $variable_values = {},
) {
  my $arg_defs = $def->{args};
  my $arg_nodes = $node->{arguments};
  DEBUG and _debug("_get_argument_values", $arg_defs, $arg_nodes, $variable_values, eval { $JSON->encode($node) });
  return {} if !$arg_defs;
  my @bad = grep { !exists $arg_nodes->{$_} and !defined $arg_defs->{$_}{default_value} and $arg_defs->{$_}{type}->isa('GraphQL::Type::NonNull') } keys %$arg_defs;
  die GraphQL::Error->new(
    message => "Argument '$bad[0]' of type ".
      "'@{[$arg_defs->{$bad[0]}{type}->to_string]}' not given.",
    nodes => [ $node ],
  ) if @bad;
  @bad = grep {
    ref($arg_nodes->{$_}) eq 'SCALAR' and
    $variable_values->{${$arg_nodes->{$_}}} and
    !_type_will_accept($arg_defs->{$_}{type}, $variable_values->{${$arg_nodes->{$_}}}{type})
  } keys %$arg_defs;
  die GraphQL::Error->new(
    message => "Variable '\$${$arg_nodes->{$bad[0]}}' of type '@{[$variable_values->{${$arg_nodes->{$bad[0]}}}{type}->to_string]}'".
      " where expected '@{[$arg_defs->{$bad[0]}{type}->to_string]}'.",
    nodes => [ $node ],
  ) if @bad;
  my @novar = grep {
    ref($arg_nodes->{$_}) eq 'SCALAR' and
    (!$variable_values or !exists $variable_values->{${$arg_nodes->{$_}}}) and
    !defined $arg_defs->{$_}{default_value} and
    $arg_defs->{$_}{type}->isa('GraphQL::Type::NonNull')
  } keys %$arg_defs;
  die GraphQL::Error->new(
    message => "Argument '$novar[0]' of type ".
      "'@{[$arg_defs->{$novar[0]}{type}->to_string]}'".
      " was given variable '\$${$arg_nodes->{$novar[0]}}' but no runtime value.",
    nodes => [ $node ],
  ) if @novar;
  my @enumfail = grep {
    ref($arg_nodes->{$_}) eq 'REF' and
    ref(${$arg_nodes->{$_}}) eq 'SCALAR' and
    !$arg_defs->{$_}{type}->isa('GraphQL::Type::Enum')
  } keys %$arg_defs;
  die GraphQL::Error->new(
    message => "Argument '$enumfail[0]' of type ".
      "'@{[$arg_defs->{$enumfail[0]}{type}->to_string]}'".
      " was given ${${$arg_nodes->{$enumfail[0]}}} which is enum value.",
    nodes => [ $node ],
  ) if @enumfail;
  my @enumstring = grep {
    defined($arg_nodes->{$_}) and
    !ref($arg_nodes->{$_})
  } grep $arg_defs->{$_}{type}->isa('GraphQL::Type::Enum'), keys %$arg_defs;
  die GraphQL::Error->new(
    message => "Argument '$enumstring[0]' of type ".
      "'@{[$arg_defs->{$enumstring[0]}{type}->to_string]}'".
      " was given '$arg_nodes->{$enumstring[0]}' which is not enum value.",
    nodes => [ $node ],
  ) if @enumstring;
  return {} if !$arg_nodes;
  my %coerced_values;
  for my $name (keys %$arg_defs) {
    my $arg_def = $arg_defs->{$name};
    my $arg_type = $arg_def->{type};
    my $argument_node = $arg_nodes->{$name};
    my $default_value = $arg_def->{default_value};
    DEBUG and _debug("_get_argument_values($name)", $arg_def, $arg_type, $argument_node, $default_value);
    if (!exists $arg_nodes->{$name}) {
      # none given - apply type arg's default if any. already validated perl
      $coerced_values{$name} = $default_value if exists $arg_def->{default_value};
      next;
    } elsif (ref($argument_node) eq 'SCALAR') {
      # scalar ref means it's a variable. already validated perl
      $coerced_values{$name} =
        ($variable_values && $variable_values->{$$argument_node} && $variable_values->{$$argument_node}{value})
        // $default_value;
      next;
    } elsif (ref($argument_node) eq 'REF') {
      # double ref means it's an enum value. JSON land, needs convert/validate
      $coerced_values{$name} = $$$argument_node;
    } else {
      # query literal. JSON land, needs convert/validate
      $coerced_values{$name} = $argument_node;
    }
    next if !exists $coerced_values{$name};
    DEBUG and _debug("_get_argument_values($name after initial)", $arg_def, $arg_type, $argument_node, $default_value, $JSON->encode(\%coerced_values));
    eval { $coerced_values{$name} = $arg_type->graphql_to_perl($coerced_values{$name}) };
    DEBUG and _debug("_get_argument_values($name after coerce)", $JSON->encode(\%coerced_values));
    if ($@) {
      my $error = $@;
      $error =~ s#\s+at.*line\s+\d+\.#.#;
      die GraphQL::Error->new(
        message => "Argument '$name' got invalid value"
          . " @{[$JSON->encode($coerced_values{$name})]}.\nExpected '"
          . $arg_type->to_string . "'.\n$error",
        nodes => [ $node ],
      );
    }
  }
  \%coerced_values;
}

fun _type_will_accept(
  (ConsumerOf['GraphQL::Role::Input']) $arg_type,
  (ConsumerOf['GraphQL::Role::Input']) $var_type,
) {
  return 1 if $arg_type == $var_type;
  $arg_type = $arg_type->of if $arg_type->isa('GraphQL::Type::NonNull');
  $var_type = $var_type->of if $var_type->isa('GraphQL::Type::NonNull');
  return 1 if $arg_type == $var_type;
  '';
}

# $root_value is either a hash with fieldnames as keys and either data
#   or coderefs as values
# OR it's just a coderef itself
# OR it's an object which gets tried for fieldname as method
# any code gets called with obvious args
fun _default_field_resolver(
  CodeLike | HashRef | InstanceOf $root_value,
  HashRef $args,
  Any $context,
  HashRef $info,
) {
  my $field_name = $info->{field_name};
  my $property = is_HashRef($root_value)
    ? $root_value->{$field_name}
    : $root_value;
  DEBUG and _debug('_default_field_resolver', $root_value, $field_name, $args, $property);
  if (eval { CodeLike->($property); 1 }) {
    DEBUG and _debug('_default_field_resolver', 'codelike');
    return $property->($args, $context, $info);
  }
  if (is_InstanceOf($root_value) and $root_value->can($field_name)) {
    DEBUG and _debug('_default_field_resolver', 'method');
    return $root_value->$field_name($args, $context, $info);
  }
  $property;
}

1;
