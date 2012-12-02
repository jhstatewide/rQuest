require "yaml"
require "pstore"
require "pp"
require "fileutils"

import 'org.bukkit.event.Event'
import "org.bukkit.inventory.ItemStack"

java_import Java::net.milkbowl.vault.Vault
java_import Java::net.milkbowl.vault.economy.Economy
java_import Java::net.milkbowl.vault.economy.EconomyResponse
java_import Java::net.milkbowl.vault.permission.Permission

import 'org.bukkit.Material'
import 'org.bukkit.inventory.ItemStack'
import 'org.bukkit.util.Vector'
import 'org.bukkit.ChatColor'


Plugin.is {
  name "RQuest"
  version "0.1"
  author "Joshua Harding"
  commands :rquest => {
    :rquest => "/rquest - interface to rquest"
  }
}

class RQuestStore
  def initialize
    @store = PStore.new("plugins/RQuest/rquest.pstore")
    # @store.ultra_safe = true
  end

  # return true if the player is in a quest
  def in_quest?(player_name)
    @store.transaction(true) do
      return @store[player_name] && @store[player_name].current_quest_id
    end
  end

  def quest_done(player_name)
    pd = lookup(player_name)
    pd.current_quest_id = nil
    # puts "PD: #{pd.inspect}"
    if pd.num_completed_quests == nil
      pd.num_completed_quests = 1
    else
      pd.num_completed_quests += 1
    end
    update(pd)
  end

  def quests_completed(player_name)
    qd = lookup(player_name)
    return qd.num_completed_quests
  end

  # process a player starting a quest
  def start_quest(player_name, quest_id)
    pd = lookup(player_name)
    pd.current_quest_id = quest_id
    update(pd)
  end

  # returns the current quest_id of the player
  def current_quest(player_name)
    return lookup(player_name).current_quest_id
  end

  private

  # save the player data to the database
  def update(player_data)
    @store.transaction do
      @store[player_data.player_name] = player_data
    end
  end

  # lookup a player and create a record if we don't exist...
  def lookup(player_name)
    @store.transaction do
      @store[player_name] = RQuestPlayerData.new unless @store[player_name]
      @store[player_name].player_name = player_name
      return @store[player_name]
    end
  end
end

class RQuestPlayerData
  attr_accessor :player_name, :current_quest_id, :num_completed_quests
end

class RQuestChecker
  class << self
    # check the player (this is an entity)
    # against the quest...
    def check(player, quest)
      inventory = player.getInventory
      # okay, quest is a hash with :required
      # iterate over required and see if the inventory contains
      # what we need...
      quest[:required].each do |req_hash|
        puts "We require #{req_hash.inspect}"
        # inventory has contains(material_id, amount)
        unless inventory.contains(req_hash[:id], req_hash[:quantity])
          return false
        end
      end
      return true
    end
  end
end

class RQuest < RubyPlugin
  
  def colorize(s)
    map = {
      '|r' => ChatColor::RED,
      '|R' => ChatColor::DARK_RED,
      '|y' => ChatColor::YELLOW,
      '|Y' => ChatColor::GOLD,
      '|g' => ChatColor::GREEN,
      '|G' => ChatColor::DARK_GREEN,
      '|c' => ChatColor::AQUA,
      '|C' => ChatColor::DARK_AQUA,
      '|b' => ChatColor::BLUE,
      '|B' => ChatColor::DARK_BLUE,
      '|p' => ChatColor::LIGHT_PURPLE,
      '|P' => ChatColor::DARK_PURPLE,
      '|s' => ChatColor::GRAY,
      '|S' => ChatColor::DARK_GRAY,
      '|w' => ChatColor::WHITE,
      '|k' => ChatColor::BLACK,
    }

    map.each do|i,v|
      s = s.gsub(i, v.to_s)
    end

    s
  end
  
  def onEnable
    puts "Enabling rQuest..."
    @quest_store = RQuestStore.new
    # first step, load config file...
    unless File.exist?("plugins/RQuest")
      FileUtils.mkdir("plugins/RQuest")
      File.open("plugins/RQuest/config.yaml", "w") do |f|
        f.puts("# CONFIG FOR RQUEST")
      end
    end
    @quest_data = YAML.load(IO.read("plugins/RQuest/config.yaml"))
    
    @SERVER = org.bukkit.Bukkit.getServer
    # STDERR.puts @quest_data.inspect
    @VAULT = @SERVER.getPluginManager.getPlugin("Vault")
    setup_economy()
  end
  
  def setup_economy
    raise "Vault can't be used" unless @VAULT
    rsp = @SERVER.getServicesManager.getRegistration(Economy.java_class)
    @ECONOMY = rsp.getProvider
  end

  def onEvent(event)
    # puts "WE GOT AN EVENT: #{event.inspect}"
  end
  
  def send(sender, message)
    fancy_plug = colorize("|c[|YRQuest|c] |w")
    sender.sendMessage(fancy_plug + colorize(message))
  end
  
  def broadcast(message)
    fancy_plug = colorize("|c[|YRQuest|c] |w")
    @SERVER.broadcastMessage(fancy_plug + colorize(message))
  end

  def onCommand(sender, command, label, args)
    player_name = sender.getName
    # puts "working with #{player_name}"
    # see what command we are trying
    args = args.to_a
    # handle no arguments...
    if args.length == 0
      send(sender, "/rquest give, /rquest done, /rquest info, /rquest drop")
      return
    end

    if args[0].casecmp("info") == 0
      show_quest(sender)
      return true
    end

    if args[0].casecmp("drop") == 0
      unless @quest_store.in_quest?(player_name)
        send(sender, "You can't drop a quest... you don't have one!")
        return true
      end
      # now, grab our current quest...
      quest = quest(@quest_store.current_quest(player_name))
      # ok, figure out the reward and subtract double from our balance...
      amount_to_subtract = quest[:reward] * 2

      @ECONOMY.withdrawPlayer(player_name, amount_to_subtract)
      send(sender, "You dropped the quest but it cost $#{amount_to_subtract}")
      broadcast("#{player_name} just dropped quest #{quest[:name]}!")
      broadcast("They were penalized $#{amount_to_subtract}!")
      @quest_store.quest_done(player_name)

      return true
    end

    if args[0].casecmp("give") == 0
      if @quest_store.in_quest?(player_name)
        send(sender, "You are already in a quest!")
        show_quest(sender)
        return true
      else
        send(sender, "OK! Quest Started!")

        start_quest(player_name)
        quest = quest(@quest_store.current_quest(player_name))
        broadcast("#{player_name} just started quest #{quest[:name]}!")
        send(sender, quest[:on_start])
        show_quest(sender)
        return true
      end
    end

    if args[0].casecmp("done")
      unless @quest_store.in_quest?(player_name)
        send(sender,"You're not currently in a quest...")
        return true
      end
      if RQuestChecker.check(sender, quest(@quest_store.current_quest(player_name)))
        send(sender, "Your quest is complete!")

        # okay, now take the items away...
        current_quest = quest(@quest_store.current_quest(player_name))
        current_quest[:required].each do |req_hash|
          puts "Removing #{req_hash.inspect} from player..."
          id = req_hash[:id]
          quantity = req_hash[:quantity]
          remove_from_inventory(sender, id, quantity)
        end

        # now reward time!
        amount_to_add = current_quest[:reward]

        @ECONOMY.depositPlayer(player_name, amount_to_add)
        sender.sendMessage(current_quest[:on_complete])
        #sender.sendMessage("You have been rewarded with $#{amount_to_add}")
        @quest_store.quest_done(player_name)
        broadcast("#{player_name} just completed quest #{current_quest[:name]}!")
        broadcast("They were awarded with $#{amount_to_add}!")
        broadcast("They have completed #{@quest_store.quests_completed(player_name)} quests!")
        return true
      else
        send(sender, "Your quest is not complete.")
        return true
      end
    end

    puts "Didn't match anything..."

    return true
  end

  # provided a quest id, returns the quest hash...
  def quest(quest_id)
    @quest_data[:quests].each do |qh|
      return qh if qh[:quest_id] == quest_id
    end
    # we couldn't find it...
    return nil
  end

  def onDisable
    puts "Disabling rQuest..."
  end

  private
  def remove_from_inventory(player, item_id, quantity)
    total_removed = 0
    player.getInventory.getContents.each do |is|
      if is && is.getTypeId == item_id && total_removed < quantity
        durability = is.getDurability()
        default_durability = is.getType().getMaxDurability()
        # puts "The durability is #{durability} and the default is #{default_durability}"
        unless is.getDurability() == 0
          raise "Can't redeem used goods!" if  is.getDurability() < is.getType().getMaxDurability()
        end
        while is.getAmount >= 0 && total_removed < quantity
          if is.getAmount <= 1
            player.getInventory.removeItem(is)
          else
            # decrement until nothing...
            is.setAmount(is.getAmount - 1)
          end
          # if there's only 1 item in the item stack, destroy it!
          total_removed += 1
        end
      end
    end
  end

  def show_quest(player)
    player_name = player.getName
    # puts "Looking up quest for #{player_name}"
    quest_id = @quest_store.current_quest(player_name)
    # puts "The current quest id is: #{quest_id}"
    quest = quest(quest_id)
    # puts "The quest is: #{quest.inspect}"
    return false unless quest
    send(player, "Quest: #{quest[:name]}")
    send(player, "Reward: $#{quest[:reward]}")
    quest[:required].each do |req_hash|
      send(player, "You must get #{req_hash[:quantity]} of #{req_hash[:description]}")
    end
  end

  # return a random quest ID
  def random_quest()
    @quest_data[:quests].random_element()[:quest_id]
  end

  def start_quest(player_name)
    quest_id = random_quest()
    @quest_store.start_quest(player_name, quest_id)
  end
end

class Array
  def random_element
    self[rand(length)]
  end
end
