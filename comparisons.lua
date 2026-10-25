-- Built-in fun comparisons for the API value row, used when Buddy has no brain (or it's busy,
-- capped or answers badly). US prices, rough but believable; landmarks are construction costs.
-- Every entry has the same shape a brain reply has: value.lua's V.fill turns it into a line.

local C = {}

local function T(emoji, thing, price, count, part)
  return { emoji = emoji, thing = thing, price = price, count = count, part = part }
end

C.LIST = {
  T("🍬", "pack of gum", 2, "That's {n} packs of gum", "{n} of a pack of gum"),
  T("🍫", "chocolate bar", 2, "That's {n} chocolate bars", "{n} of a chocolate bar"),
  T("🍩", "donut", 2.5, "That's {n} donuts", "{n} of a donut"),
  T("☕", "Tim Hortons double-double", 2.5, "That's {n} double-doubles", "{n} of a double-double"),
  T("🌮", "taco", 3, "That's {n} tacos", "{n} of a taco"),
  T("🍕", "slice of pizza", 4, "That's {n} slices of pizza", "{n} of a slice of pizza"),
  T("🍟", "large fries", 4, "That's {n} large fries", "{n} of a large fries"),
  T("🐠", "goldfish", 4, "Enough for {n} goldfish", "{n} of a goldfish"),
  T("🍦", "ice cream cone", 5, "That's {n} ice cream cones", "{n} of an ice cream cone"),
  T("🥣", "box of cereal", 5, "That's {n} boxes of cereal", "{n} of a box of cereal"),
  T("🦆", "rubber duck", 5, "That's {n} rubber ducks", "{n} of a rubber duck"),
  T("☕", "Starbucks latte", 6, "That's {n} Starbucks lattes", "{n} of a Starbucks latte"),
  T("🍔", "Big Mac", 6, "That's {n} Big Macs", "{n} of a Big Mac"),
  T("🌭", "ballpark hot dog", 7, "That's {n} ballpark hot dogs", "{n} of a ballpark hot dog"),
  T("🧋", "bubble tea", 7, "That's {n} bubble teas", "{n} of a bubble tea"),
  T("🍿", "movie popcorn", 9, "That's {n} tubs of movie popcorn", "{n} of a tub of movie popcorn"),
  T("🌯", "burrito", 11, "That's {n} burritos", "{n} of a burrito"),
  T("🦴", "bag of dog treats", 12, "That's {n} bags of dog treats", "{n} of a bag of dog treats"),
  T("🥑", "avocado toast", 14, "That's {n} avocado toasts", "{n} of an avocado toast"),
  T("🎟️", "movie ticket", 15, "That's {n} movie tickets", "{n} of a movie ticket"),
  T("📚", "paperback novel", 15, "That's {n} paperback novels", "{n} of a paperback novel"),
  T("🍕", "large pepperoni pizza", 18, "That's {n} large pepperoni pizzas", "{n} of a large pepperoni pizza"),
  T("🧽", "car wash", 20, "That's {n} car washes", "{n} of a car wash"),
  T("🪴", "houseplant", 25, "That's {n} houseplants", "{n} of a houseplant"),
  T("🏀", "basketball", 30, "That's {n} basketballs", "{n} of a basketball"),
  T("🎳", "night of bowling", 40, "That's {n} nights of bowling", "{n} of a night of bowling"),
  T("🥩", "steak dinner", 55, "That's {n} steak dinners", "{n} of a steak dinner"),
  T("⛽", "tank of gas", 60, "That's {n} tanks of gas", "{n} of a tank of gas"),
  T("🦞", "lobster dinner", 60, "That's {n} lobster dinners", "{n} of a lobster dinner"),
  T("🎮", "new video game", 70, "That's {n} new video games", "{n} of a new video game"),
  T("🧱", "LEGO set", 80, "That's {n} LEGO sets", "{n} of a LEGO set"),
  T("🛹", "skateboard", 100, "That's {n} skateboards", "{n} of a skateboard"),
  T("🎤", "concert ticket", 110, "That's {n} concert tickets", "{n} of a concert ticket"),
  T("👟", "pair of sneakers", 120, "That's {n} pairs of sneakers", "{n} of a pair of sneakers"),
  T("🏈", "football game ticket", 150, "That's {n} football tickets", "{n} of a football ticket"),
  T("🎧", "pair of AirPods", 180, "That's {n} pairs of AirPods", "{n} of a pair of AirPods"),
  T("🎸", "acoustic guitar", 300, "That's {n} acoustic guitars", "{n} of an acoustic guitar"),
  T("🏂", "snowboard", 450, "That's {n} snowboards", "{n} of a snowboard"),
  T("🕹️", "PlayStation 5", 500, "That's {n} PlayStation 5s", "{n} of a PlayStation 5"),
  T("☕", "fancy espresso machine", 700, "That's {n} fancy espresso machines", "{n} of a fancy espresso machine"),
  T("📺", "big-screen TV", 800, "That's {n} big-screen TVs", "{n} of a big-screen TV"),
  T("📱", "iPhone", 1000, "That's {n} iPhones", "{n} of an iPhone"),
  T("⛷️", "season ski pass", 1000, "That's {n} season ski passes", "{n} of a season ski pass"),
  T("🚵", "mountain bike", 1500, "That's {n} mountain bikes", "{n} of a mountain bike"),
  T("🐕", "golden retriever puppy", 2000, "Enough for {n} golden retriever puppies", "{n} of a golden retriever puppy"),
  T("💻", "MacBook Pro", 2500, "That's {n} MacBook Pros", "{n} of a MacBook Pro"),
  T("🚐", "family road trip", 2500, "That's {n} family road trips", "{n} of a family road trip"),
  T("🚜", "riding lawn mower", 3000, "That's {n} riding lawn mowers", "{n} of a riding lawn mower"),
  T("🦙", "alpaca", 3000, "Enough for {n} alpacas", "{n} of an alpaca"),
  T("🏰", "Disney World family trip", 6000, "That's {n} Disney World family trips", "{n} of a Disney World family trip"),
  T("🛁", "backyard hot tub", 8000, "That's {n} backyard hot tubs", "{n} of a backyard hot tub"),
  T("⌚", "Rolex", 12000, "That's {n} Rolexes", "{n} of a Rolex"),
  T("✈️", "first-class flight to Tokyo", 12000, "That's {n} first-class flights to Tokyo", "{n} of a first-class flight to Tokyo"),
  T("🚗", "used Honda Civic", 15000, "That's {n} used Honda Civics", "{n} of a used Honda Civic"),
  T("🏍️", "Harley-Davidson", 25000, "That's {n} Harley-Davidsons", "{n} of a Harley-Davidson"),
  T("🎈", "hot air balloon", 30000, "That's {n} hot air balloons", "{n} of a hot air balloon"),
  T("🚤", "fishing boat", 35000, "That's {n} fishing boats", "{n} of a fishing boat"),
  T("🎓", "year of college", 40000, "That's {n} years of college", "{n} of a year of college"),
  T("🚘", "Tesla Model 3", 40000, "That's {n} Tesla Model 3s", "{n} of a Tesla Model 3"),
  T("🚙", "Jeep Wrangler", 45000, "That's {n} Jeep Wranglers", "{n} of a Jeep Wrangler"),
  T("🛻", "Ford F-150", 55000, "That's {n} Ford F-150s", "{n} of a Ford F-150"),
  T("🏠", "tiny house", 80000, "That's {n} tiny houses", "{n} of a tiny house"),
  T("🚚", "food truck", 100000, "That's {n} food trucks", "{n} of a food truck"),
  T("🏎️", "Porsche 911", 130000, "That's {n} Porsche 911s", "{n} of a Porsche 911"),
  T("🐂", "Lamborghini Huracán", 250000, "That's {n} Lamborghinis", "{n} of a Lamborghini"),
  T("🛖", "lake cabin", 350000, "That's {n} lake cabins", "{n} of a lake cabin"),
  T("🏡", "average American house", 420000, "That's {n} average American houses", "{n} of an average American house"),
  T("🐎", "racehorse", 500000, "That's {n} racehorses", "{n} of a racehorse"),
  T("🎠", "carousel", 1000000, "That's {n} carousels", "{n} of a carousel"),
  T("🛥️", "yacht", 2000000, "That's {n} yachts", "{n} of a yacht"),
  T("🚀", "Bugatti Chiron", 3000000, "That's {n} Bugatti Chirons", "{n} of a Bugatti Chiron"),
  T("🏯", "castle in Scotland", 3000000, "That's {n} Scottish castles", "{n} of a castle in Scotland"),
  T("🏝️", "private island", 5000000, "That's {n} private islands", "{n} of a private island"),
  T("📣", "30-second Super Bowl ad", 7000000, "That's {n} Super Bowl ads", "{n} of a 30-second Super Bowl ad"),
  T("🛩️", "private jet", 20000000, "That's {n} private jets", "{n} of a private jet"),
  T("🎢", "roller coaster", 20000000, "That's {n} roller coasters", "{n} of a roller coaster"),
  T("🌉", "Golden Gate Bridge (1937 prices)", 35000000, "Enough to build {n} Golden Gate Bridges at 1937 prices",
    "{n} of the Golden Gate Bridge at 1937 prices"),
  T("🏙️", "Empire State Building (1931 prices)", 41000000, "Enough to build {n} Empire State Buildings at 1931 prices",
    "{n} of the Empire State Building at 1931 prices"),
  T("🗼", "Eiffel Tower paint job", 60000000, "That's {n} Eiffel Tower paint jobs", "{n} of an Eiffel Tower paint job"),
  T("🛰️", "rocket launch", 70000000, "That's {n} rocket launches", "{n} of a rocket launch"),
  T("✈️", "Boeing 747", 400000000, "That's {n} Boeing 747s", "{n} of a Boeing 747"),
  T("🏟️", "NBA arena", 1000000000, "That's {n} NBA arenas", "{n} of an NBA arena"),
  T("🔭", "Hubble Space Telescope", 1500000000, "That's {n} Hubble telescopes", "{n} of the Hubble Space Telescope"),
  T("🌆", "Burj Khalifa", 1500000000, "Enough to build {n} Burj Khalifas", "{n} of the Burj Khalifa"),
  T("⚾", "baseball team", 2000000000, "That's {n} baseball teams", "{n} of a baseball team"),
  T("🤖", "Mars rover", 2700000000, "That's {n} Mars rovers", "{n} of a Mars rover"),
}

-- A thing for this amount: 2 to 500 of it, or 0.000001% to 1% of one. Things in recent
-- (newest first) are skipped; when every candidate is recent, the one used longest ago.
function C.pick(figure, recent)
  local age = {}
  for i, thing in ipairs(recent or {}) do
    if age[thing] == nil then age[thing] = i end
  end
  local cands, fresh = {}, {}
  for _, c in ipairs(C.LIST) do
    if (c.price * 2 <= figure and c.price >= figure / 500) or (c.price >= figure * 100 and c.price <= figure * 1e8) then
      cands[#cands + 1] = c
      if not age[c.thing] then fresh[#fresh + 1] = c end
    end
  end
  if #fresh > 0 then return fresh[math.random(#fresh)] end
  if #cands == 0 then
    local cheapest = C.LIST[1]
    for _, c in ipairs(C.LIST) do
      if c.price < cheapest.price then cheapest = c end
    end
    return cheapest
  end
  local best = cands[1]
  for _, c in ipairs(cands) do
    if age[c.thing] > age[best.thing] then best = c end
  end
  return best
end

return C
