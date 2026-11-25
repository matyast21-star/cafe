-- Carta editable desde el panel del barista
create table public.menu_categories (
  id text primary key check (id ~ '^[a-z0-9-]{2,30}$'),
  carta text not null check (carta in ('carta','pasteleria')),
  name text not null check (char_length(name) between 2 and 60),
  note text,
  cols jsonb,
  img text,
  vid text,
  sort int not null default 0
);
create table public.menu_items (
  id bigserial primary key,
  category_id text not null references public.menu_categories(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 80),
  description text check (description is null or char_length(description) <= 300),
  size text check (size is null or char_length(size) <= 40),
  price int not null check (price between 0 and 1000000),
  price2 int check (price2 is null or price2 between 0 and 1000000),
  tags text[] not null default '{}' check (tags <@ array['vegan','veg','new']::text[]),
  available boolean not null default true,
  sort int not null default 0,
  updated_at timestamptz not null default now(),
  updated_by text
);
create index menu_items_cat_idx on public.menu_items(category_id, sort, id);
alter table public.menu_categories enable row level security;
alter table public.menu_items enable row level security;
revoke all on public.menu_categories, public.menu_items from anon, authenticated;

create or replace function private.menu_json(p_all boolean) returns json
language sql security definer set search_path = public, private stable as $$
  select coalesce(json_agg(json_build_object(
    'id', c.id, 'carta', c.carta, 'name', c.name, 'note', c.note, 'cols', c.cols, 'img', c.img, 'vid', c.vid,
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'name', i.name, 'description', i.description, 'size', i.size,
                         'price', i.price, 'price2', i.price2, 'tags', i.tags, 'available', i.available) order by i.sort, i.id)
                       from menu_items i where i.category_id = c.id and (p_all or i.available)), '[]'::json)
  ) order by c.sort), '[]'::json)
  from menu_categories c
$$;

create or replace function public.menu_get() returns json
language sql security definer set search_path = public, private stable as $$ select private.menu_json(false) $$;

create or replace function public.staff_menu_get() returns json
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  return private.menu_json(true);
end $$;

create or replace function public.staff_menu_save(p_id bigint, p_category text, p_name text, p_description text, p_size text,
  p_price int, p_price2 int, p_tags text[], p_available boolean) returns json
language plpgsql security definer set search_path = public, private as $$
declare v_id bigint;
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  if char_length(btrim(coalesce(p_name,''))) < 2 then raise exception 'invalid_item_name'; end if;
  if p_price is null or p_price < 0 then raise exception 'invalid_price'; end if;
  if not exists (select 1 from menu_categories where id = p_category) then raise exception 'invalid_category'; end if;
  if p_id is null then
    insert into menu_items(category_id, name, description, size, price, price2, tags, available, sort, updated_by)
    values (p_category, btrim(p_name), nullif(btrim(coalesce(p_description,'')),''), nullif(btrim(coalesce(p_size,'')),''), p_price, p_price2,
            coalesce(p_tags,'{}'), coalesce(p_available,true),
            coalesce((select max(sort)+1 from menu_items where category_id = p_category), 0), lower(auth.jwt() ->> 'email'))
    returning id into v_id;
  else
    update menu_items set category_id = p_category, name = btrim(p_name), description = nullif(btrim(coalesce(p_description,'')),''),
      size = nullif(btrim(coalesce(p_size,'')),''), price = p_price, price2 = p_price2, tags = coalesce(p_tags,'{}'),
      available = coalesce(p_available,true), updated_at = now(), updated_by = lower(auth.jwt() ->> 'email')
    where id = p_id returning id into v_id;
    if v_id is null then raise exception 'item_not_found'; end if;
  end if;
  return private.menu_json(true);
end $$;

create or replace function public.staff_menu_delete(p_id bigint) returns json
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  delete from menu_items where id = p_id;
  if not found then raise exception 'item_not_found'; end if;
  return private.menu_json(true);
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.menu_get(), public.staff_menu_get(), public.staff_menu_save(bigint,text,text,text,text,int,int,text[],boolean), public.staff_menu_delete(bigint) from public;
grant execute on function public.menu_get() to anon, authenticated;
grant execute on function public.staff_menu_get() to authenticated;
grant execute on function public.staff_menu_save(bigint,text,text,text,text,int,int,text[],boolean) to authenticated;
grant execute on function public.staff_menu_delete(bigint) to authenticated;

-- Carga inicial: Carta Magnolias 2026 y Pastelería familiar
insert into public.menu_categories(id,carta,name,note,cols,img,vid,sort) values
('sartenes','carta','Sartenes de huevo','con hogaza de masa madre',null,'sarten.jpg','v-sarten',0),
('desayunos','carta','Desayunos','incluyen café o té',null,'v-cheesecake.jpg',null,1),
('smoothies','carta','Smoothies y tostadas','smoothies y yogurt incluyen café o té',null,'tostadas.jpg',null,2),
('sandwiches','carta','Sándwiches','en baguette o ciabatta',null,'terraza.jpg',null,3),
('ensalada','carta','Ensalada del día','elige tu proteína',null,'tapa.jpg',null,4),
('cafe','carta','Cafetería','café de especialidad','["Simple","Doble"]'::jsonb,'capuccino.jpg',null,5),
('especiales','carta','Cafés de la casa','con syrups ODK',null,'taza.jpg',null,6),
('te','carta','Té, infusiones y chocolate','David Rio, English Tea Shop y Dilmah',null,'tes.jpg',null,7),
('frio','carta','Fríos y mocktails','café de especialidad, versión fría',null,'espresso-orange.jpg',null,8),
('bebidas','carta','Bebidas','jugos, limonadas y más',null,'mocktails.jpg',null,9),
('pas-trad','pasteleria','Tradicionales',null,null,null,null,100),
('pas-veg','pasteleria','Veganas',null,null,null,null,101);

insert into public.menu_items(category_id,name,description,size,price,price2,tags,sort) values
('sartenes','Sartén de huevo + tocino','Huevos revueltos acompañados de tocino y hogaza de masa madre.',null,5500,null,array[]::text[],0),
('sartenes','Sartén de huevo + cebolla crispy','Huevos revueltos acompañados de cebolla crispy y hogaza de masa madre.',null,5500,null,array['veg']::text[],1),
('sartenes','Sartén de huevo + palta','Huevos revueltos acompañados de palta y hogaza de masa madre.',null,5500,null,array['veg']::text[],2),
('sartenes','Sartén de huevo + queso','Huevos revueltos acompañados de queso mantecoso y hogaza de masa madre.',null,5500,null,array['veg']::text[],3),
('sartenes','Sartén de huevo + jamón','Huevos revueltos acompañados de jamón acaramelado y hogaza de masa madre.',null,5500,null,array[]::text[],4),
('desayunos','Palta y sésamo','Pan integral con palta y semillas de sésamo tostado.',null,3800,null,array['veg']::text[],0),
('desayunos','Palta y huevo','Pan integral con palta y huevo revuelto.',null,3800,null,array['veg']::text[],1),
('desayunos','Baguette huevo','Pan baguette con huevo revuelto.',null,3800,null,array['veg']::text[],2),
('desayunos','Queso y jamón','Pan baguette con queso y jamón acaramelado.',null,3800,null,array[]::text[],3),
('desayunos','Huevo y jamón','Pan baguette con huevo revuelto y jamón acaramelado.',null,3800,null,array[]::text[],4),
('desayunos','Queso y palta','Pan baguette con queso fundido y palta.',null,3800,null,array['veg']::text[],5),
('desayunos','Huevo y queso','Pan baguette con queso fundido y huevo revuelto.',null,3800,null,array['veg']::text[],6),
('desayunos','Jamón y palta','Pan baguette con jamón acaramelado y palta.',null,3800,null,array[]::text[],7),
('smoothies','Smoothie de cacao','Plátano, leche vegetal, mantequilla de maní y cacao, con granola casera y fruta.',null,5500,null,array['vegan']::text[],0),
('smoothies','Smoothie de frutos rojos','Frutos rojos, leche vegetal y mantequilla de maní, con granola casera y fruta.',null,5500,null,array['vegan']::text[],1),
('smoothies','Yogurt con granola y fruta','Yogurt natural, granola casera y fruta del día.',null,4500,null,array['veg']::text[],2),
('smoothies','Tostadas francesas frutos rojos y Nutella','Pan remojado en huevo, leche, canela y azúcar, dorado en mantequilla, con Nutella, mermelada de frambuesa y frutos rojos.',null,4000,null,array['veg','new']::text[],3),
('smoothies','Tostadas francesas plátano y maní','Pan dorado en mantequilla con mantequilla de maní, plátano, canela y salsa de chocolate.',null,4000,null,array['veg','new']::text[],4),
('sandwiches','Baguette de campo','Pan baguette, queso mantecoso, jamón acaramelado, pesto, tomate cherry y lechuga.',null,6200,null,array[]::text[],0),
('sandwiches','Om-Ñam vegano','Pan ciabatta, pesto, hummus, palta, semillas de sésamo y lechuga.',null,6200,null,array['vegan']::text[],1),
('sandwiches','Palta capresse','Pan baguette, pesto, palta, tomate cherry, queso fresco, berros y reducción de aceto balsámico.',null,6500,null,array['veg']::text[],2),
('sandwiches','Palta huevo queso','Pan ciabatta, palta, huevo revuelto, queso mantecoso y berros.',null,6500,null,array['veg']::text[],3),
('sandwiches','Bocatta crespa','Pan ciabatta, queso crema, palta, tomates rebozados en aceite de oliva y berros.',null,6500,null,array['veg']::text[],4),
('ensalada','Ensalada del día','Lechuga y berros, palta, tomate cherry, queso fresco, reducción de aceto balsámico y sésamo tostado. Proteína a elección: hummus de garbanzo, jamón acaramelado o tocino.',null,5500,null,array['veg']::text[],0),
('cafe','Espresso','La bebida más icónica del café: molienda fina y agua a alta presión.',null,2000,2500,array['vegan']::text[],0),
('cafe','Americano','Agua caliente con un espresso encima, para mantener la crema del café.',null,2000,2500,array['vegan']::text[],1),
('cafe','Cortado','La leche “corta” la intensidad del espresso y suaviza su acidez.',null,2400,2700,array['veg']::text[],2),
('cafe','Capuccino','Base de espresso seguida de un lácteo emulsionado.',null,2900,3200,array['veg']::text[],3),
('especiales','Latte caramelo','Espresso simple, syrup de caramelo ODK y lácteo emulsionado.',null,3900,null,array['veg']::text[],0),
('especiales','Mocaccino','Cacao dulce, espresso doble y lácteo emulsionado.',null,3900,null,array['veg']::text[],1),
('especiales','Capuccino vainilla','Espresso doble, syrup de vainilla ODK y lácteo emulsionado.',null,3900,null,array['veg']::text[],2),
('especiales','Capuccino avellana y chocolate','Espresso doble, syrup de avellana ODK, lácteo emulsionado y cubierta de chocolate.',null,3900,null,array['veg']::text[],3),
('te','Chai latte','Té chai David Rio emulsionado con leche y canela en polvo.',null,4000,null,array['veg']::text[],0),
('te','Dirty chai latte','Té chai David Rio con espresso, emulsionado con leche y canela.',null,4700,null,array['veg']::text[],1),
('te','Matcha latte','Matcha David Rio de Kyushu, prefectura de Kagoshima. Suave y vibrante.',null,4500,null,array['veg']::text[],2),
('te','Matcha latte caramelo','Matcha David Rio con syrup de caramelo ODK.',null,4700,null,array['veg']::text[],3),
('te','Té English Tea Shop / Dilmah','Té orgánico de Sri Lanka.',null,1900,null,array['vegan']::text[],4),
('te','Infusiones naturales','Canela y naranja · Limón, menta y jengibre · Flor de jamaica.',null,2000,null,array['vegan','new']::text[],5),
('te','Chocolate caliente','Chocolate Bonhomia estilo europeo con cacao orgánico 100% de Perú.',null,4000,null,array['veg']::text[],6),
('te','Babyccino','Leche con cacao, espuma de leche, chocolate rallado y marshmallows.',null,3500,null,array[]::text[],7),
('frio','Iced caramel coffee','Espresso doble, leche, hielo frappé y syrup de caramelo.',null,4200,null,array['veg']::text[],0),
('frio','Iced latte coffee','Espresso doble, leche y hielo frappé.',null,4000,null,array['veg']::text[],1),
('frio','Iced mocaccino coffee','Espresso doble, leche y hielo frappé.',null,4200,null,array['veg']::text[],2),
('frio','Iced latte chai','Té chai David Rio, hielo, leche y un toque de canela.',null,4500,null,array['veg']::text[],3),
('frio','Iced dirty chai','Té chai David Rio, hielo, leche y espresso doble.',null,4700,null,array['veg']::text[],4),
('frio','Iced matcha latte caramelo','Matcha David Rio, hielo, leche y syrup de caramelo.',null,4500,null,array['veg']::text[],5),
('frio','Iced dirty matcha','Matcha David Rio, hielo, leche y espresso doble.',null,4700,null,array['veg']::text[],6),
('frio','Berriccino','Mix de berries con menta y café de especialidad, agua tónica y hielo.',null,4500,null,array['vegan']::text[],7),
('frio','Vibra Tonic','Maracuyá macerada en café de especialidad, agua tónica y hielo.',null,4500,null,array['vegan']::text[],8),
('frio','Espresso orange','Jugo de naranja, agua tónica, hielo y espresso doble.',null,3500,null,array['vegan']::text[],9),
('frio','Affogato','Espresso doble con helado de vainilla.',null,3000,null,array['veg']::text[],10),
('frio','Café helado','Espresso doble, lácteo, helado de vainilla y crema batida.',null,4500,null,array['veg']::text[],11),
('bebidas','Jugos de fruta','Consulta por los sabores disponibles.',null,3200,null,array['vegan']::text[],0),
('bebidas','Limonadas','Menta jengibre o tradicional.',null,3000,null,array['vegan']::text[],1),
('bebidas','Leches con sabor','Consulta por los sabores disponibles.',null,3500,null,array['veg']::text[],2),
('bebidas','Agua mineral con y sin gas',null,null,1500,null,array['vegan']::text[],3),
('bebidas','Bebidas',null,null,1800,null,array['vegan']::text[],4),
('bebidas','Extra: leche sin lactosa',null,null,800,null,array['veg']::text[],5),
('bebidas','Extra: leche vegetal',null,null,800,null,array['vegan']::text[],6),
('pas-trad','Pie de limón','Masa sablée, crema cítrica con limón natural y merengue suizo.','Diámetro 28 cm',23000,null,array['veg']::text[],0),
('pas-trad','Cheesecake de frambuesa','Base de galletas y mantequilla, relleno de queso crema y mermelada de frambuesa.','Diámetro 27 cm',25000,null,array['veg']::text[],1),
('pas-trad','Kuchen sureño','Masa quebrada con suave relleno de crema y berries.','Diámetro 28 cm',25000,null,array['veg']::text[],2),
('pas-veg','Carrot cake','Bizcocho de zanahoria y naranja, crema de castañas de cajú, nueces y semillas de zapallo.','Diámetro 20 cm',28000,null,array['vegan']::text[],0),
('pas-veg','Brownie de plátano','Plátano y cacao con harina de avena, cubierto de nueces.','22 × 8 cm',10000,null,array['vegan']::text[],1),
('pas-veg','Queque de zanahoria','Bizcocho de zanahoria y naranja con nueces, semillas de zapallo y glaseado.','22 × 8 cm',12000,null,array['vegan']::text[],2),
('pas-veg','Snicker crudivegano','Base de avena con dátiles, mantequilla de maní, manjar de dátiles, chocolate semi amargo y maní.','22 × 8 cm',12000,null,array['vegan']::text[],3);
