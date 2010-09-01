package DBIx::Class::Schema::Loader::DBI::InterBase;

use strict;
use warnings;
use mro 'c3';
use base qw/DBIx::Class::Schema::Loader::DBI/;
use Carp::Clan qw/^DBIx::Class/;
use List::Util 'first';
use namespace::clean;

our $VERSION = '0.07001';

=head1 NAME

DBIx::Class::Schema::Loader::DBI::InterBase - DBIx::Class::Schema::Loader::DBI
Firebird Implementation.

=head1 DESCRIPTION

See L<DBIx::Class::Schema::Loader> and L<DBIx::Class::Schema::Loader::Base>.

=head1 COLUMN NAME CASE ISSUES

By default column names from unquoted DDL will be generated in lowercase, for
consistency with other backends. 

Set the L<preserve_case|DBIx::Class::Schema::Loader::Base/preserve_case> option
to true if you would like to have column names in the internal case, which is
uppercase for DDL that uses unquoted identifiers.

Do not use quoting (the L<quote_char|DBIx::Class::Storage::DBI/quote_char>
option in L<connect_info|DBIx::Class::Storage::DBI/connect_info> when in the
default C<< preserve_case => 0 >> mode.

Be careful to also not use any SQL reserved words in your DDL.

This will generate lowercase column names (as opposed to the actual uppercase
names) in your Result classes that will only work with quoting off.

Mixed-case table and column names will be ignored when this option is on and
will not work with quoting turned off.

=cut

sub _setup {
    my $self = shift;

    $self->next::method(@_);

    if (not defined $self->preserve_case) {
        warn <<'EOF';

WARNING: Assuming unquoted Firebird DDL, see
perldoc DBIx::Class::Schema::Loader::DBI::InterBase
and the 'preserve_case' option in
perldoc DBIx::Class::Schema::Loader::Base
for more information.

EOF
        $self->preserve_case(0);
    }

    if ($self->preserve_case) {
        $self->schema->storage->sql_maker->quote_char('"');
        $self->schema->storage->sql_maker->name_sep('.');
    }
    else {
        $self->schema->storage->sql_maker->quote_char(undef);
        $self->schema->storage->sql_maker->name_sep(undef);
    }
}

sub _table_pk_info {
    my ($self, $table) = @_;

    my $dbh = $self->schema->storage->dbh;
    my $sth = $dbh->prepare(<<'EOF');
SELECT iseg.rdb$field_name
FROM rdb$relation_constraints rc
JOIN rdb$index_segments iseg ON rc.rdb$index_name = iseg.rdb$index_name
WHERE rc.rdb$constraint_type = 'PRIMARY KEY' and rc.rdb$relation_name = ?
ORDER BY iseg.rdb$field_position
EOF
    $sth->execute($table);

    my @keydata;

    while (my ($col) = $sth->fetchrow_array) {
        s/^\s+//, s/\s+\z// for $col;

        push @keydata, $self->_lc($col);
    }

    return \@keydata;
}

sub _table_fk_info {
    my ($self, $table) = @_;

    my ($local_cols, $remote_cols, $remote_table, @rels);
    my $dbh = $self->schema->storage->dbh;
    my $sth = $dbh->prepare(<<'EOF');
SELECT rc.rdb$constraint_name fk, iseg.rdb$field_name local_col, ri.rdb$relation_name remote_tab, riseg.rdb$field_name remote_col
FROM rdb$relation_constraints rc
JOIN rdb$index_segments iseg ON rc.rdb$index_name = iseg.rdb$index_name
JOIN rdb$indices li ON rc.rdb$index_name = li.rdb$index_name
JOIN rdb$indices ri ON li.rdb$foreign_key = ri.rdb$index_name
JOIN rdb$index_segments riseg ON iseg.rdb$field_position = riseg.rdb$field_position and ri.rdb$index_name = riseg.rdb$index_name
WHERE rc.rdb$constraint_type = 'FOREIGN KEY' and rc.rdb$relation_name = ?
ORDER BY iseg.rdb$field_position
EOF
    $sth->execute($table);

    while (my ($fk, $local_col, $remote_tab, $remote_col) = $sth->fetchrow_array) {
        s/^\s+//, s/\s+\z// for $fk, $local_col, $remote_tab, $remote_col;

        push @{$local_cols->{$fk}},  $self->_lc($local_col);
        push @{$remote_cols->{$fk}}, $self->_lc($remote_col);
        $remote_table->{$fk} = $remote_tab;
    }

    foreach my $fk (keys %$remote_table) {
        push @rels, {
            local_columns => $local_cols->{$fk},
            remote_columns => $remote_cols->{$fk},
            remote_table => $remote_table->{$fk},
        };
    }
    return \@rels;
}

sub _table_uniq_info {
    my ($self, $table) = @_;

    my $dbh = $self->schema->storage->dbh;
    my $sth = $dbh->prepare(<<'EOF');
SELECT rc.rdb$constraint_name, iseg.rdb$field_name
FROM rdb$relation_constraints rc
JOIN rdb$index_segments iseg ON rc.rdb$index_name = iseg.rdb$index_name
WHERE rc.rdb$constraint_type = 'UNIQUE' and rc.rdb$relation_name = ?
ORDER BY iseg.rdb$field_position
EOF
    $sth->execute($table);

    my $constraints;
    while (my ($constraint_name, $column) = $sth->fetchrow_array) {
        s/^\s+//, s/\s+\z// for $constraint_name, $column;

        push @{$constraints->{$constraint_name}}, $self->_lc($column);
    }

    my @uniqs = map { [ $_ => $constraints->{$_} ] } keys %$constraints;
    return \@uniqs;
}

sub _columns_info_for {
    my $self = shift;
    my ($table) = @_;

    my $result = $self->next::method(@_);

    my $dbh = $self->schema->storage->dbh;

    local $dbh->{LongReadLen} = 100000;
    local $dbh->{LongTruncOk} = 1;

    while (my ($column, $info) = each %$result) {
        my $sth = $dbh->prepare(<<'EOF');
SELECT t.rdb$trigger_source
FROM rdb$triggers t
WHERE t.rdb$relation_name = ?
AND t.rdb$system_flag = 0 -- user defined
AND t.rdb$trigger_type = 1 -- BEFORE INSERT
EOF
        $sth->execute($table);

        while (my ($trigger) = $sth->fetchrow_array) {
            my @trig_cols = map { /^"([^"]+)/ ? $1 : uc($_) } $trigger =~ /new\.("?\w+"?)/ig;

            my ($quoted, $generator) = $trigger =~ /(?:gen_id\s* \( \s* |next \s* value \s* for \s*)(")?(\w+)/ix;

            if ($generator) {
                $generator = uc $generator unless $quoted;

                if (first { $self->_uc($_) eq $self->_uc($column) } @trig_cols) {
                    $info->{is_auto_increment} = 1;
                    $info->{sequence}          = $generator;
                    last;
                }
            }
        }

# fix up types
        $sth = $dbh->prepare(<<'EOF');
SELECT f.rdb$field_precision, f.rdb$field_scale, f.rdb$field_type, f.rdb$field_sub_type, t.rdb$type_name, st.rdb$type_name
FROM rdb$fields f
JOIN rdb$relation_fields rf ON rf.rdb$field_source = f.rdb$field_name
LEFT JOIN rdb$types t  ON f.rdb$field_type     = t.rdb$type  AND t.rdb$field_name  = 'RDB$FIELD_TYPE'
LEFT JOIN rdb$types st ON f.rdb$field_sub_type = st.rdb$type AND st.rdb$field_name = 'RDB$FIELD_SUB_TYPE'
WHERE rf.rdb$relation_name = ?
    AND rf.rdb$field_name  = ?
EOF
        $sth->execute($table, $self->_uc($column));
        my ($precision, $scale, $type_num, $sub_type_num, $type_name, $sub_type_name) = $sth->fetchrow_array;
        $scale = -$scale if $scale && $scale < 0;

        if ($type_name && $sub_type_name) {
            s/\s+\z// for $type_name, $sub_type_name;

            # fixups primarily for DBD::InterBase
            if ($info->{data_type} =~ /^(?:integer|int|smallint|bigint|-9581)\z/) {
                if ($precision && $type_name =~ /^(?:LONG|INT64)\z/ && $sub_type_name eq 'BLR') {
                    $info->{data_type} = 'decimal';
                }
                elsif ($precision && $type_name =~ /^(?:LONG|SHORT|INT64)\z/ && $sub_type_name eq 'TEXT') {
                    $info->{data_type} = 'numeric';
                }
                elsif ((not $precision) && $type_name eq 'INT64' && $sub_type_name eq 'BINARY') {
                    $info->{data_type} = 'bigint';
                }
            }
            # ODBC makes regular blobs sub_type blr
            elsif ($type_name eq 'BLOB') {
                if ($sub_type_name eq 'BINARY') {
                    $info->{data_type} = 'blob';
                }
                elsif ($sub_type_name eq 'TEXT') {
                    $info->{data_type} = 'blob sub_type text';
                }
            }
        }

        if ($info->{data_type} =~ /^(?:decimal|numeric)\z/ && defined $precision && defined $scale) {
            if ($precision == 9 && $scale == 0) {
                delete $info->{size};
            }
            else {
                $info->{size} = [$precision, $scale];
            }
        }

        if ($info->{data_type} eq '11') {
            $info->{data_type} = 'timestamp';
        }
        elsif ($info->{data_type} eq '10') {
            $info->{data_type} = 'time';
        }
        elsif ($info->{data_type} eq '9') {
            $info->{data_type} = 'date';
        }
        elsif ($info->{data_type} eq 'character varying') {
            $info->{data_type} = 'varchar';
        }
        elsif ($info->{data_type} eq 'character') {
            $info->{data_type} = 'char';
        }
        elsif ($info->{data_type} eq 'float') {
            $info->{data_type} = 'real';
        }
        elsif ($info->{data_type} eq 'int64' || $info->{data_type} eq '-9581') {
            # the constant is just in case, the query should pick up the type
            $info->{data_type} = 'bigint';
        }

        # DBD::InterBase sets scale to '0' for some reason for char types
        if ($info->{data_type} =~ /^(?:char|varchar)\z/ && ref($info->{size}) eq 'ARRAY') {
            $info->{size} = $info->{size}[0];
        }
        elsif ($info->{data_type} !~ /^(?:char|varchar|numeric|decimal)\z/) {
            delete $info->{size};
        }

# get default
        delete $info->{default_value} if $info->{default_value} && $info->{default_value} eq 'NULL';

        $sth = $dbh->prepare(<<'EOF');
SELECT rf.rdb$default_source
FROM rdb$relation_fields rf
WHERE rf.rdb$relation_name = ?
AND rf.rdb$field_name = ?
EOF
        $sth->execute($table, $self->_uc($column));
        my ($default_src) = $sth->fetchrow_array;

        if ($default_src && (my ($def) = $default_src =~ /^DEFAULT \s+ (\S+)/ix)) {
            if (my ($quoted) = $def =~ /^'(.*?)'\z/) {
                $info->{default_value} = $quoted;
            }
            else {
                $info->{default_value} = $def =~ /^-?\d/ ? $def : \$def;
            }
        }

        ${ $info->{default_value} } = 'current_timestamp'
            if ref $info->{default_value} && ${ $info->{default_value} } eq 'CURRENT_TIMESTAMP';
    }

    return $result;
}

=head1 SEE ALSO

L<DBIx::Class::Schema::Loader>, L<DBIx::Class::Schema::Loader::Base>,
L<DBIx::Class::Schema::Loader::DBI>

=head1 AUTHOR

See L<DBIx::Class::Schema::Loader/AUTHOR> and L<DBIx::Class::Schema::Loader/CONTRIBUTORS>.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
# vim:et sw=4 sts=4 tw=0:
