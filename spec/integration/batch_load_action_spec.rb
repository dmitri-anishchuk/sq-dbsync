require 'integration_helper'
require 'sq/dbsync/database/connection'
require 'sq/dbsync/loggers'
require 'sq/dbsync/batch_load_action'
require 'sq/dbsync/table_registry'
require 'sq/dbsync/static_table_plan'
require 'sq/dbsync/all_tables_plan'

describe SQD::BatchLoadAction do
  let(:overlap) { described_class.overlap }
  let!(:now)    { @now = Time.now.utc }
  let(:last_synced_at) { now - 10 }
  let(:target) { test_target }
  let(:target_table_name) { :test_table }
  let(:common_table_plan) {{
    table_name: target_table_name,
    source_table_name: :test_table,
    columns: [:id, :col1, :updated_at],
    source_db: source,
    indexes: index,
  }}
  let(:index) {{
    index_on_col1: { columns: [:col1], unique: false }
  }}
  let(:registry) { SQD::TableRegistry.new(target) }
  let(:action) { SQD::BatchLoadAction.new(
    target,
    table_plan,
    registry,
    SQD::Loggers::Null.new,
    ->{ @now }
  ) }
  let(:using_millisecond_precision) { false }

  shared_examples_for 'a batch load' do
    before do
      create_source_table_with(using_millisecond_precision,
      {
        id:         1,
        col1:       'hello',
        pii:        'don alias',
        updated_at: using_millisecond_precision ? (now - 10).to_i * 1000 : now - 10
      })

      registry.ensure_storage_exists
    end

    describe ':all columns options' do
      let(:table_plan) { using_millisecond_precision ?
        common_table_plan.merge({columns: :all, timestamp_in_millis: using_millisecond_precision}) :
        common_table_plan.merge({columns: :all})
      }

      it 'copies all columns to target' do
        action.call

        plan = OpenStruct.new(table_plan)
        target.hash_schema(plan).keys.should ==
          source.hash_schema(plan).keys
      end
    end

    describe 'when the source and destination table names differ' do
      let(:target_table_name) { :target_test_table }

      it 'copies source tables to target with matching schemas' do
        start_time = now.to_f

        action.call

        verify_schema
        verify_data
        verify_metadata(start_time)
      end
    end

    it 'handles column that does not exist in source' do
      source.alter_table :test_table do
        drop_column :col1
      end

      table_plan[:indexes] = {}
      action.call

      target[:test_table].map {|x| x.values_at(:id)}.
        should == [[1]]
    end

    it 'handles table that does not exist in source' do
      source.drop_table :test_table

      expect { action.call }.to raise_error(Sq::Dbsync::LoadError)
    end

    it 'ignores duplicates when loading data' do
      source[:test_table].insert(id: 2, col1: 'hello')
      source[:test_table].insert(id: 3, col1: 'hello')

      table_plan[:indexes][:unique_index] = {columns: [:col1], unique: true}

      action.call

      target[:test_table].count.should == 1
    end

    it 'clears partial load if a new_ table already exists' do
      setup_target_table(now)
      target.switch_table(:new_test_table, :test_table)

      source[:test_table].insert(
        id: 7,
        col1: 'old',
        updated_at: using_millisecond_precision ? (now - 600).to_i * 1000 : now - 600
      )

      target[:new_test_table].insert(
        id:         2,
        col1:       'already loaded',
        updated_at: using_millisecond_precision ? (now - 200).to_i * 1000 : now - 200
      )

      action.call

      target[:test_table].all.map {|x| x[:col1] }.sort.should ==
        ['hello', 'old'].sort
    end

    it 'catches up from last_row_at' do
      action.do_prepare
      action.extract_data
      action.load_data

      source[:test_table].insert(id: 2, col1: 'new',
          updated_at: using_millisecond_precision ? now.to_i * 1000 : now)

      @now += 600

      action.post_load

      target[:test_table].all.map {|x| x[:col1] }.sort.should ==
        ['hello', 'new'].sort
    end

    def test_tables
      {
        test_table: [source, :target_test_table],
      }
    end

    def verify_schema
      test_tables.each do |table_name, (source_db, target_table_name)|
        target.tables.should include(target_table_name)
        source_test_table_schema =
          source_db.schema(table_name).map do |column, hash|
            # Auto-increment is not copied, since it isn't relevant for
            # replicated tables and would be more complicated to support.
            # Primary key status is copied, however.
            hash.delete(:auto_increment)
            hash.delete(:ruby_default)
            [column, hash]
          end

        extract_common_db_column_info = ->(e) {
          [e[0], {
            type: e[1][:type],
            primary_key: e[1][:primary_key]
          }]
        }

        source_test_table_schema = source_test_table_schema.map do |e|
          extract_common_db_column_info.call(e)
        end

        target.schema(target_table_name).each do |column_arr|
          column_arr = extract_common_db_column_info.call(column_arr)
          source_test_table_schema.should include(column_arr)
        end
        target.indexes(target_table_name).should == index
      end
    end

    def verify_data
      test_tables.each do |table_name, (source_db, target_table_name)|
        data = target[target_table_name].all
        data.count.should == 1
        data = data[0]
        data.keys.length.should == 3
        data[:id].should == 1
        data[:col1].should == 'hello'
        data[:updated_at].to_i.should == (using_millisecond_precision ?
            (now - 10).to_i * 1000 : (now - 10).to_i)
      end
    end

    def verify_metadata(start_time)
      test_tables.each do |table_name, (source_db, target_table_name)|
        meta = registry.get(target_table_name)
        meta[:last_synced_at].should_not be_nil
        meta[:last_batch_synced_at].should_not be_nil
        meta[:last_batch_synced_at].to_i.should == start_time.to_i
        meta[:last_row_at].to_i.should == (now - 10).to_i
      end
    end
  end

  context 'with MySQL source' do
    let(:source) { test_source(:source) }

    context 'with timestamp in seconds' do
      let(:table_plan) { common_table_plan }

      it_should_behave_like 'a batch load'
    end

    context 'with timestamp in milliseconds' do
      let(:using_millisecond_precision) { true }
      let(:table_plan) { common_table_plan.merge({timestamp_in_millis: true}) }

      it_should_behave_like 'a batch load'
    end

    context 'with timestamp not specified' do
      let(:using_millisecond_precision) { false }
      let(:table_plan) { common_table_plan }

      it_should_behave_like 'a batch load'
    end
  end

  context 'with PG source' do
    let(:source) { test_source(:postgres) }

    context 'with timestamp in seconds' do
      let(:table_plan) { common_table_plan }

      it_should_behave_like 'a batch load'
    end

    context 'with timestamp in milliseconds' do
      let(:using_millisecond_precision) { true }
      let(:table_plan) { common_table_plan.merge({timestamp_in_millis: true}) }

      it_should_behave_like 'a batch load'
    end

    context 'with timestamp not specified' do
      let(:using_millisecond_precision) { false }
      let(:table_plan) { common_table_plan }

      it_should_behave_like 'a batch load'
    end

    it 'loads records with time zones' do
      table_plan = {
        table_name: :test_table,
        source_table_name: :test_table,
        columns: [:id, :col1, :updated_at, :ts_with_tz],
        source_db: source,
        indexes: index,
      }

      action = SQD::BatchLoadAction.new(target,
                                        table_plan,
                                        registry,
                                        SQD::Loggers::Null.new,
                                        ->{ @now })

      create_pg_source_table_with(
        id:         1,
        col1:       'hello',
        pii:        'don alias',
        created_at: '2012-01-01 01:01:01',
        updated_at: '2012-01-01 01:01:01',
        ts_with_tz: '2012-01-01 01:01:01+02',
      )

      registry.ensure_storage_exists

      action.call

      target[:test_table].count.should == 1
      target[:test_table].to_a.last[:ts_with_tz].should == Time.utc(2011, 12, 31, 23, 1, 1)
    end
  end
end
