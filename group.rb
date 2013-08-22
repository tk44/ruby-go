require_relative "stone_constants"

# A group keeps the list of its stones, the updated number of "lives" (empty intersections around),
# and whatever status information we need to decide what happens to a group (e.g. when a
# group is killed or merged with another group, etc.).
# Note that most of the work here is to keep this status information up to date.
class Group
  attr_reader :goban, :stones, :lives, :color
  attr_reader :merged_with, :merged_by, :killed_by, :sentinel, :ndx
  attr_writer :merged_with, :merged_by # only used in this file
  
  def Group.init(goban)
    @@ndx = 0
    @@sentinel = Group.new(goban, Stone.new(goban,-1,-1,-1), -1)
    goban.merged_groups.push(@@sentinel)
    goban.killed_groups.push(@@sentinel)
  end
  
  # Create a new group. Always with a single stone.
  def initialize(goban,stone,lives)
    @goban = goban
    @stones = [stone]
    @lives = lives
    @color = stone.color
    @merged_with = nil # a group
    @merged_by = nil # a stone
    @killed_by = nil # a stone
    @ndx = @@ndx # unique index (more for debug)
    $log.debug("New group created #{self}") if $debug
    @@ndx += 1
  end

  def recycle!(stone,lives)
    @stones.clear
    @stones.push(stone)
    @lives = lives
    @color = stone.color
    @merged_with = @merged_by = @killed_by = nil
    $log.debug("Use (new) recycled group #{self}") if $debug
    return self
  end
  
  # Recycles a group from garbage
  # Leaves the index @ndx unchanged  
  def Group.recycle_new(goban,stone,lives)
    group = goban.garbage_groups.pop
    return group.recycle!(stone,lives) if group
    return Group.new(goban,stone,lives)
  end
  
  # Returns the total number of group created (mostly for debug)
  def Group.count
    @@ndx
  end
  
  def to_s
    s = "{group ##{@ndx} of #{@stones.size}"+
      " #{Stone::color_name(@color)} stones ["
    @stones.each { |stone| s << "#{stone.as_move}," }
    s.chop!
    s << "], lives:#{@lives}"
    s << " MERGED with ##{@merged_with.ndx}" if @merged_with
    s << " KILLED by #{@killed_by.as_move}" if @killed_by
    s << "}"
    return s
  end

  # debug dump does not have more to display now that stones are simpler
  # TODO: remove it unless stones get more state data to display
  def debug_dump
    return to_s
  end
  
  def stones_dump
    return stones.map{|s| s.as_move}.sort.join(",")
  end

  # Counts the lives of a stone that are not already in the group
  # (the stone is to be added or removed)
  def lives_added_by_stone(stone)
    lives = 0
    stone.neighbors.each do |life|
      next if life.color != EMPTY
      lives += 1 unless true == life.neighbors.each { |s| break(true) if s.group == self and s != stone }
      # Using any? or detect makes the code clearer but slower :(
      # lives += 1 unless life.neighbors.any? { |s| s.group == self and s != stone }
    end
    $log.debug("#{lives} lives added by #{stone} for group #{self}") if $debug
    return lives
  end
  
  # Connect a new stone or a merged stone to this group
  def connect_stone(stone, on_merge = false)
    $log.debug("Connecting #{stone} to group #{self} (on_merge=#{on_merge})") if $debug
    @stones.push(stone)
    @lives += lives_added_by_stone(stone)
    @lives -= 1 if !on_merge # minus one since the connection itself removes 1
    raise "Unexpected error (lives<0 on connect)" if @lives<0 # can be 0 if suicide-kill
    $log.debug("Final group: #{self}") if $debug
  end
  
  # Disconnect a stone
  # on_merge must be true for merge or unmerge-related call 
  def disconnect_stone(stone, on_merge = false)
    $log.debug("Disconnecting #{stone} from group #{self} (on_merge=#{on_merge})") if $debug
    # groups of 1 stone become empty groups (->garbage)
    if @stones.size > 1
      @lives -= lives_added_by_stone(stone)
      @lives += 1 if !on_merge # see comment in connect_stone
      raise "Unexpected error (lives<0 on disconnect)" if @lives<0 # can be 0 if suicide-kill
    else
      @goban.garbage_groups.push(self)
      $log.debug("Group going to recycle bin: #{self}") if $debug
    end
    # we always remove them in the reverse order they came
    if @stones.pop != stone then raise "Unexpected error (disconnect order)" end
  end
  
  # When a new stone appears next to this group
  def attacked_by(stone)
    @lives -= 1
    die_from(stone) if @lives <= 0 # also check <0 so we can raise in die_from method
  end

  # When a group of stones reappears because we undo
  # NB: it can never kill anything
  def attacked_by_resuscitated(stone)
    @lives -= 1
    $log.debug("#{self} attacked by resuscitated #{stone}") if $debug
    raise "Unexpected error (lives<1 on attack by resucitated)" if @lives<1
  end

  # Stone parameter is just for debug for now
  def not_attacked_anymore(stone)
    @lives += 1
    $log.debug("#{self} not attacked anymore by #{stone}") if $debug
  end
  
  # Merges a subgroup with this group
  def merge(subgroup, by_stone)
    raise "Invalid merge" if subgroup.merged_with == self or subgroup == self or @color != subgroup.color
    $log.debug("Merging subgroup:#{subgroup} to main:#{self}") if $debug
    subgroup.stones.each do |s| 
      s.set_group_on_merge(self)
      connect_stone(s, true)
    end
    subgroup.merged_with = self
    subgroup.merged_by = by_stone
    @goban.merged_groups.push(subgroup)
    $log.debug("After merge: subgroup:#{subgroup} main:#{self}") if $debug
  end

  # Reverse of merge
  def unmerge(subgroup)
    $log.debug("Unmerging subgroup:#{subgroup} from main:#{self}") if $debug
    subgroup.stones.reverse_each do |s|
      disconnect_stone(s, true)
      s.set_group_on_merge(subgroup)
    end
    subgroup.merged_by = subgroup.merged_with = nil
    $log.debug("After unmerge: subgroup:#{subgroup} main:#{self}") if $debug
  end
  
  # This must be called on the main group (stone.group)
  def unmerge_from(stone)
    while (subgroup = @goban.merged_groups.last).merged_by == stone and subgroup.merged_with == self
      unmerge(@goban.merged_groups.pop)
    end
  end
  
  # Called when the group has no more life left
  def die_from(killer_stone)
    $log.debug("Group dying: #{self}") if $debug
    raise "Unexpected error (lives<0)" if @lives < 0
    stones.each do |stone|
      stone.unique_enemies(@color).each { |enemy| enemy.not_attacked_anymore(stone) }
      stone.die
    end
    @killed_by = killer_stone
    @goban.killed_groups.push(self)   
    $log.debug("Group dead: #{self}") if $debug
  end
  
  # Called when "undo" operation removes the killer stone of this group
  def resuscitate
    @killed_by = nil
    @lives = 1 # always comes back with a single life
    stones.each do |stone|
      stone.resuscitate_in(self)
      stone.unique_enemies(@color).each { |enemy| enemy.attacked_by_resuscitated(stone) }
    end
  end

  def Group.resuscitate_from(killer_stone,goban)
    while goban.killed_groups.last().killed_by == killer_stone do
      group = goban.killed_groups.pop
      $log.debug("taking back #{killer_stone} so we resuscitate #{group.debug_dump}") if $debug
      group.resuscitate()
    end
  end
  
end
