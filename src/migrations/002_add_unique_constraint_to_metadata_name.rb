Sequel.migration do
  up do
    return unless table_exists?(:metadata)

    has_unique = begin
      indexes(:metadata).values.any? { |idx| idx[:unique] && idx[:columns] == [:name] }
    rescue
      false
    end
    return if has_unique

    duplicates = self[:metadata].select(:name).group(:name).having { count(:name) > 1 }.all
    raise "Cannot add unique constraint: duplicate names found: #{duplicates.map { |d| d[:name] }.join(', ')}" if duplicates.any?

    create_table(:metadata_new) do
      String :name, null: false
      String :value
      unique :name
    end
    self[:metadata_new].insert(self[:metadata].select(:name, :value))
    drop_table(:metadata)
    rename_table(:metadata_new, :metadata)
  end

  down do
    return unless table_exists?(:metadata)

    has_unique = begin
      indexes(:metadata).values.any? { |idx| idx[:unique] && idx[:columns] == [:name] }
    rescue
      false
    end
    return unless has_unique

    create_table(:metadata_old) do
      String :name, null: false
      String :value
      index :name
    end
    self[:metadata_old].insert(self[:metadata].select(:name, :value))
    drop_table(:metadata)
    rename_table(:metadata_old, :metadata)
  end
end

