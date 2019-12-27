/****************************************************
				BLOOD SYSTEM
****************************************************/
//Blood levels. These are percentages based on the species blood_volume var.
var/const/BLOOD_VOLUME_SAFE =    85
var/const/BLOOD_VOLUME_OKAY =    75
var/const/BLOOD_VOLUME_BAD =     60
var/const/BLOOD_VOLUME_SURVIVE = 40
var/const/CE_STABLE_THRESHOLD = 0.5

/mob/living/carbon/human/var/datum/reagents/vessel // Container for blood and BLOOD ONLY. Do not transfer other chems here.
/mob/living/carbon/human/var/var/pale = 0          // Should affect how mob sprite is drawn, but currently doesn't.

//Initializes blood vessels
/mob/living/carbon/human/proc/make_blood()

	if(vessel)
		return

	if(species.flags & NO_BLOOD)
		return

	vessel = new/datum/reagents(species.blood_volume)
	vessel.my_atom = src

	if(!should_have_organ(O_HEART)) //We want the var for safety but we can do without the actual blood.
		return

	vessel.add_reagent("blood",species.blood_volume)

//Resets blood data
/mob/living/carbon/human/proc/fixblood()
	for(var/datum/reagent/blood/B in vessel.reagent_list)
		if(B.id == "blood")
			B.data = list(	"donor"=src,"viruses"=null,"species"=species.name,"blood_DNA"=dna.unique_enzymes,"blood_colour"= species.get_blood_colour(src),"blood_type"=dna.b_type,	\
							"resistances"=null,"trace_chem"=null, "virus2" = null, "antibodies" = list())
			B.color = B.data["blood_colour"]

// Takes care blood loss and regeneration
/mob/living/carbon/human/handle_blood()
	if(inStasisNow())
		return

	if(!should_have_organ(O_HEART))
		return

	if(stat != DEAD && bodytemperature >= 170)	//Dead or cryosleep people do not pump the blood.

		var/blood_volume_raw = vessel.get_reagent_amount("blood")
		var/blood_volume = round((blood_volume_raw/species.blood_volume)*100) // Percentage.

		//Blood regeneration if there is some space
		if(blood_volume_raw < species.blood_volume)
			var/datum/reagent/blood/B = locate() in vessel.reagent_list //Grab some blood
			if(B) // Make sure there's some blood at all
				if(B.data["donor"] != src) //If it's not theirs, then we look for theirs
					for(var/datum/reagent/blood/D in vessel.reagent_list)
						if(D.data["donor"] == src)
							B = D
							break

				B.volume += 0.1 // regenerate blood VERY slowly
				if(CE_BLOODRESTORE in chem_effects)
					B.volume += chem_effects[CE_BLOODRESTORE]

		// Damaged heart virtually reduces the blood volume, as the blood isn't
		// being pumped properly anymore.
		if(species && should_have_organ(O_HEART))
			var/obj/item/organ/internal/heart/heart = internal_organs_by_name[O_HEART]

			if(!heart)
				blood_volume = 0
			else if(heart.is_broken())
				blood_volume *= 0.3
			else if(heart.is_bruised())
				blood_volume *= 0.7
			else if(heart.damage)
				blood_volume *= 0.8

		//Effects of bloodloss
		var/dmg_coef = 1				//Lower means less damage taken
		var/threshold_coef = 1			//Lower means the damage caps off lower

		if(CE_STABLE in chem_effects)
			dmg_coef = 0.5
			threshold_coef = 0.75
//	These are Bay bits, do some sort of calculation.
//			dmg_coef = min(1, 10/chem_effects[CE_STABLE]) //TODO: add effect for increased damage
//			threshold_coef = min(dmg_coef / CE_STABLE_THRESHOLD, 1)

		if(blood_volume >= BLOOD_VOLUME_SAFE)
			if(pale)
				pale = 0
				update_icons_body()
		else if(blood_volume >= BLOOD_VOLUME_OKAY)
			if(!pale)
				pale = 1
				update_icons_body()
				var/word = pick("dizzy","woosey","faint")
				to_chat(src, "<font color='red'>You feel [word]</font>")
			if(prob(1))
				var/word = pick("dizzy","woosey","faint")
				to_chat(src, "<font color='red'>You feel [word]</font>")
			if(getOxyLoss() < 20 * threshold_coef)
				adjustOxyLoss(3 * dmg_coef)
		else if(blood_volume >= BLOOD_VOLUME_BAD)
			if(!pale)
				pale = 1
				update_icons_body()
			eye_blurry = max(eye_blurry,6)
			if(getOxyLoss() < 50 * threshold_coef)
				adjustOxyLoss(10 * dmg_coef)
			adjustOxyLoss(1 * dmg_coef)
			if(prob(15))
				Paralyse(rand(1,3))
				var/word = pick("dizzy","woosey","faint")
				to_chat(src, "<font color='red'>You feel extremely [word]</font>")
		else if(blood_volume >= BLOOD_VOLUME_SURVIVE)
			adjustOxyLoss(5 * dmg_coef)
//			adjustToxLoss(3 * dmg_coef)
			if(prob(15))
				var/word = pick("dizzy","woosey","faint")
				to_chat(src, "<font color='red'>You feel extremely [word]</font>")
		else //Not enough blood to survive (usually)
			if(!pale)
				pale = 1
				update_icons_body()
			eye_blurry = max(eye_blurry,6)
			Paralyse(3)
			adjustToxLoss(3 * dmg_coef)
			adjustOxyLoss(75 * dmg_coef) // 15 more than dexp fixes (also more than dex+dexp+tricord)

		// Without enough blood you slowly go hungry.
		if(blood_volume < BLOOD_VOLUME_SAFE)
			if(nutrition >= 300)
				nutrition -= 10
			else if(nutrition >= 200)
				nutrition -= 3

		//Bleeding out
		var/blood_max = 0
		var/blood_loss_divisor = 30.01	//lower factor = more blood loss

		// Some species bleed out differently
		blood_loss_divisor /= species.bloodloss_rate
		var/open_wound
		var/list/do_spray = list()

		// Some modifiers can make bleeding better or worse.  Higher multiplers = more bleeding.
		var/blood_loss_modifier_multiplier = 1.0
		for(var/datum/modifier/M in modifiers)
			if(!isnull(M.bleeding_rate_percent))
				blood_loss_modifier_multiplier += (M.bleeding_rate_percent - 1.0)

		blood_loss_divisor /= blood_loss_modifier_multiplier


		//This 30 is the "baseline" of a cut in the "vital" regions (head and torso).
		for(var/obj/item/organ/external/temp in bad_external_organs)
			if(!(temp.status & ORGAN_BLEEDING) || (temp.robotic >= ORGAN_ROBOT))
				continue
			for(var/datum/wound/W in temp.wounds)
				if(W.bleeding())
					open_wound = TRUE
					if(temp.applied_pressure)
						if(ishuman(temp.applied_pressure))
							var/mob/living/carbon/human/H = temp.applied_pressure
							H.bloody_hands(src, 0)
						var/min_eff_damage = max(0, W.damage - 10) / 6
						blood_max += max(min_eff_damage, W.damage - 30) / 40
					else
						blood_max += (W.damage / blood_loss_divisor)
				if(temp.status & ORGAN_ARTERY_CUT)
					var/bleed_amount = round(vessel.total_volume / (temp.applied_pressure || !open_wound ? 450 : 300))
					if(bleed_amount)
						if(open_wound)
							blood_max += bleed_amount / blood_loss_divisor
							do_spray += temp.name
						else
							blood_max += W.damage / blood_loss_divisor

			if(temp.open)
				blood_max += 2 //Yer stomach is cut open

		if(world.time >= next_blood_squirt && istype(loc, /turf) && do_spray.len)
			visible_message("<span class='danger'>Blood squirts from \the [src]'s [pick(do_spray)]!</span>", "<span class='danger'><font size='3'>Blood is squirting out of your [pick(do_spray)]!</font></span>")
			eye_blurry = 2
			Stun(1)
			next_blood_squirt = world.time + 100
			var/turf/sprayloc = get_turf(src)
			blood_max -= drip(round(blood_max/3), sprayloc)
			if(blood_max > 0)
				blood_max -= blood_squirt(blood_max, sprayloc)
				if(blood_max > 0)
					drip(blood_max, get_turf(src))
		else
			drip(blood_max)

/mob/living/carbon/human
	var/next_blood_squirt = 0

//Makes a blood drop, leaking amt units of blood from the mob
/mob/living/carbon/human/proc/drip(var/amt as num, var/tar = src, var/spraydir)
	if(remove_blood(amt))
		blood_splatter(tar, src, spray_dir = spraydir)

#define BLOOD_SPRAY_DISTANCE 2
/mob/living/carbon/human/proc/blood_squirt(var/amt, var/turf/sprayloc)
	if(amt <= 0 || !istype(sprayloc))
		return
	var/spraydir = pick(alldirs)
	amt = round(amt/BLOOD_SPRAY_DISTANCE, 1)
	var/bled = 0
	spawn(0)
		for(var/i = 1 to BLOOD_SPRAY_DISTANCE)
			sprayloc = get_step(sprayloc, spraydir)
			if(!istype(sprayloc) || sprayloc.density)
				break
			var/hit_mob
			for(var/thing in sprayloc)
				var/atom/A = thing
				if(!A.simulated)
					continue

				if(ishuman(A))
					var/mob/living/carbon/human/H = A
					if(!H.lying)
						H.bloody_body(src)
						H.bloody_hands(src)
						var/blinding = FALSE
						if(ran_zone("head", 75))
							blinding = TRUE
							for(var/obj/item/I in list(H.head, H.glasses, H.wear_mask))
								if(I && (I.body_parts_covered & EYES))
									blinding = FALSE
									break
						if(blinding)
							H.eye_blurry = max(H.eye_blurry, 10)
							H.eye_blind = max(H.eye_blind, 5)
							to_chat(H, "<span class='danger'>You are blinded by a spray of blood!</span>")
						else
							to_chat(H, "<span class='danger'>You are hit by a spray of blood!</span>")
						hit_mob = TRUE

				if(hit_mob || !A.CanPass(src, sprayloc))
					break
			drip(amt, sprayloc, spraydir)
			bled += amt
	return bled
#undef BLOOD_SPRAY_DISTANCE

/mob/living/carbon/human/proc/remove_blood(var/amt)
	if(!should_have_organ(O_HEART)) //TODO: Make drips come from the reagents instead.
		return 0

	if(!amt)
		return 0

	if(amt > vessel.get_reagent_amount("blood"))
		amt = vessel.get_reagent_amount("blood") - 1	// Bit of a safety net; it's impossible to add blood if there's not blood already in the vessel.

	return vessel.remove_reagent("blood",amt * (src.mob_size/MOB_MEDIUM))

/****************************************************
				BLOOD TRANSFERS
****************************************************/

//Gets blood from mob to the container, preserving all data in it.
/mob/living/carbon/proc/take_blood(obj/item/weapon/reagent_containers/container, var/amount)

	var/datum/reagent/B = get_blood(container.reagents)
	if(!B)
		B = new /datum/reagent/blood
	B.holder = container
	B.volume += amount

	//set reagent data
	B.data["donor"] = src
	if (!B.data["virus2"])
		B.data["virus2"] = list()
	B.data["virus2"] |= virus_copylist(src.virus2)
	B.data["antibodies"] = src.antibodies
	B.data["blood_DNA"] = copytext(src.dna.unique_enzymes,1,0)
	B.data["blood_type"] = copytext(src.dna.b_type,1,0)

	// Putting this here due to return shenanigans.
	if(istype(src,/mob/living/carbon/human))
		var/mob/living/carbon/human/H = src
		B.data["blood_colour"] = H.species.get_blood_colour(H)
		B.color = B.data["blood_colour"]

	var/list/temp_chem = list()
	for(var/datum/reagent/R in src.reagents.reagent_list)
		temp_chem += R.id
		temp_chem[R.id] = R.volume
	B.data["trace_chem"] = list2params(temp_chem)
	return B

//For humans, blood does not appear from blue, it comes from vessels.
/mob/living/carbon/human/take_blood(obj/item/weapon/reagent_containers/container, var/amount)

	if(!should_have_organ(O_HEART))
		return null

	if(vessel.get_reagent_amount("blood") < amount)
		return null

	. = ..()
	vessel.remove_reagent("blood",amount) // Removes blood if human

//Transfers blood from container ot vessels
/mob/living/carbon/proc/inject_blood(var/datum/reagent/blood/injected, var/amount)
	if (!injected || !istype(injected))
		return
	var/list/sniffles = virus_copylist(injected.data["virus2"])
	for(var/ID in sniffles)
		var/datum/disease2/disease/sniffle = sniffles[ID]
		infect_virus2(src,sniffle,1)
	if (injected.data["antibodies"] && prob(5))
		antibodies |= injected.data["antibodies"]
	var/list/chems = list()
	chems = params2list(injected.data["trace_chem"])
	for(var/C in chems)
		src.reagents.add_reagent(C, (text2num(chems[C]) / species.blood_volume) * amount)//adds trace chemicals to owner's blood
	reagents.update_total()

//Transfers blood from reagents to vessel, respecting blood types compatability.
/mob/living/carbon/human/inject_blood(var/datum/reagent/blood/injected, var/amount)

	if(!should_have_organ(O_HEART))
		reagents.add_reagent("blood", amount, injected.data)
		reagents.update_total()
		return

	var/datum/reagent/blood/our = get_blood(vessel)

	if (!injected || !our)
		return
	if(blood_incompatible(injected.data["blood_type"],our.data["blood_type"],injected.data["species"],our.data["species"]) )
		reagents.add_reagent("toxin",amount * 0.5)
		reagents.update_total()
	else
		vessel.add_reagent("blood", amount, injected.data)
		vessel.update_total()
	..()

//Gets human's own blood.
/mob/living/carbon/proc/get_blood(datum/reagents/container)
	var/datum/reagent/blood/res = locate() in container.reagent_list //Grab some blood
	if(res) // Make sure there's some blood at all
		if(res.data["donor"] != src) //If it's not theirs, then we look for theirs
			for(var/datum/reagent/blood/D in container.reagent_list)
				if(D.data["donor"] == src)
					return D
	return res

proc/blood_incompatible(donor,receiver,donor_species,receiver_species)
	if(!donor || !receiver) return 0

	if(donor_species && receiver_species)
		if(donor_species != receiver_species)
			return 1

	var/donor_antigen = copytext(donor,1,length(donor))
	var/receiver_antigen = copytext(receiver,1,length(receiver))
	var/donor_rh = (findtext(donor,"+")>0)
	var/receiver_rh = (findtext(receiver,"+")>0)

	if(donor_rh && !receiver_rh) return 1
	switch(receiver_antigen)
		if("A")
			if(donor_antigen != "A" && donor_antigen != "O") return 1
		if("B")
			if(donor_antigen != "B" && donor_antigen != "O") return 1
		if("O")
			if(donor_antigen != "O") return 1
		//AB is a universal receiver.
	return 0

proc/blood_splatter(var/target,var/datum/reagent/blood/source,var/large, var/spray_dir)

	var/obj/effect/decal/cleanable/blood/B
	var/decal_type = /obj/effect/decal/cleanable/blood/splatter
	var/turf/T = get_turf(target)
	var/synth = 0

	if(istype(source,/mob/living/carbon/human))
		var/mob/living/carbon/human/M = source
		if(M.isSynthetic()) synth = 1
		source = M.get_blood(M.vessel)

	// Are we dripping or splattering?
	var/list/drips = list()
	// Only a certain number of drips (or one large splatter) can be on a given turf.
	for(var/obj/effect/decal/cleanable/blood/drip/drop in T)
		drips |= drop.drips
		qdel(drop)
	if(!large && drips.len < 3)
		decal_type = /obj/effect/decal/cleanable/blood/drip

	// Find a blood decal or create a new one.
	B = locate(decal_type) in T
	if(!B)
		B = new decal_type(T)

	var/obj/effect/decal/cleanable/blood/drip/drop = B
	if(istype(drop) && drips && drips.len && !large)
		drop.overlays |= drips
		drop.drips |= drips

	// If there's no data to copy, call it quits here.
	if(!source)
		return B

	// Update appearance.
	if(source.data["blood_colour"])
		B.basecolor = source.data["blood_colour"]
		B.synthblood = synth
		B.update_icon()

	if(spray_dir)
		B.icon_state = "squirt"
		B.dir = spray_dir

	// Update blood information.
	if(source.data["blood_DNA"])
		B.blood_DNA = list()
		if(source.data["blood_type"])
			B.blood_DNA[source.data["blood_DNA"]] = source.data["blood_type"]
		else
			B.blood_DNA[source.data["blood_DNA"]] = "O+"

	// Update virus information.
	if(source.data["virus2"])
		B.virus2 = virus_copylist(source.data["virus2"])

	B.fluorescent  = 0
	B.invisibility = 0
	return B
