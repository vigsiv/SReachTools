function varargout = getSReachLagOverapprox(sys, target_tube,...
    disturbance_set, options)
% Get the overapproximation of the stoch reach set
% ============================================================================
%
% This function will compute the overapproximation of the stochastic reach
% set via Algorithm 2 in
% 
%      J. D. Gleason, A. P. Vinod, and M. M. K. Oishi. 2018. Lagrangian 
%      Approximations for Stochastic Reachability of a Target Tube. 
%      online. (2018). https://arxiv.org/abs/1810.07118
%
% Usage: See examples/lagrangianApproximations.m
%   
% ============================================================================
%
% [overapprox_set, overapprox_tube] = getSReachLagUnderapprox(sys,...
%       target_tube, disturbance_set)
%
% Inputs:
% -------
%   sys             - LtiSystem object
%   target_tube     - Tube object 
%   disturbance_set - Polyhedron object (bounded disturbance set)
%   options         - Struct of reach set options, see SReachSetOptions
%
% Outputs:
% --------
%   overapprox_set - Polyhedron object for the overapproximation of the 
%                    stochastic reach set
%   overapprox_tube- [Optional] Tube comprising of an overapproximation of the
%                    stochastic reach sets across the time horizon
%
% Notes:
% * From computational geometry, intersections and Minkowski differences are
%   best performed in facet representation and Minkowski sums are best
%   performed in vertex representation. However, since in this computation,
%   all three operations are required, scalability of the algorithm is severly
%   hampered, despite theoretical elgance.
%
% ============================================================================
%
%   This function is part of the Stochastic Reachability Toolbox.
%   License for the use of this function is given in
%        https://github.com/unm-hscl/SReachTools/blob/master/LICENSE
%

    inpar = inputParser();
    inpar.addRequired('sys', @(x) validateattributes(x, ...
        {'LtiSystem', 'LtvSystem'}, {'nonempty'}));
    inpar.addRequired('target_tube', @(x) validateattributes(x, ...
        {'Tube'}, {'nonempty'}));
    inpar.addRequired('disturbance', @(x) validateattributes(x, ...
        {'Polyhedron','SReachEllipsoid'}, {'nonempty'}));
    
    try
        inpar.parse(sys, target_tube, disturbance_set);
    catch cause_exc
        exc = SrtInvalidArgsError.withFunctionName();
        exc = addCause(exc, cause_exc);
        throwAsCaller(exc);
    end
    
    % Check if prob_str and method_str of options are consistent        
    if ~strcmpi(options.prob_str, 'term')
        throwAsCaller(...
            SrtInvalidArgsError('Mismatch in prob_str in the options'));
    end
    if ~strcmpi(options.method_str, 'lag-over')
        throwAsCaller(...
            SrtInvalidArgsError('Mismatch in method_str in the options'));
    end            
    
    switch lower(options.compute_style)
        case 'vhmethod'
            %% Use vertex-facet enumeration requiring recursion
            [effective_target_tube] = computeViaRecursion(sys, target_tube,...
                disturbance_set, options);
        case 'support'
            %% Use recursion-free support function approach
            [effective_target_tube] = computeViaSupportFn(sys, target_tube,...
                disturbance_set, options);
        otherwise
            throw(SrtInvalidArgsError('Invalid computation style specified'));
    end
    
    varargout{1} = effective_target_tube(1);
    if nargout > 1
        varargout{2} = effective_target_tube;
    end
end

function [effective_target_tube] = computeViaRecursion(sys, target_tube,...
    disturbance_set, options)   
% This private function implements the recursion-based computation which
% internally requires vertex-facet enumeration => performs really well for
% low dimension systems but scales very poorly
%
% ============================================================================
%
%   This function is part of the Stochastic Reachability Toolbox.
%   License for the use of this function is given in
%        https://github.com/unm-hscl/SReachTools/blob/master/LICENSE
%

    tube_length = length(target_tube);
    if sys.islti()
        inverted_state_matrix = inv(sys.state_mat);
        minus_bu = (-sys.input_mat) * sys.input_space;
        minus_scaled_dist_set = (-sys.dist_mat) * disturbance_set;
    end
    if options.verbose >= 1
        fprintf('Time_horizon: %d\n', tube_length-1);
    end

    effective_target_tube = repmat(Polyhedron(), tube_length, 1);
    effective_target_tube(end) = target_tube(end);
    if tube_length > 1
        for itt = tube_length-1:-1:1
            current_time = itt - 1;
            if options.verbose >= 1
                fprintf('Computation for time step: %d\n', current_time);
            end
            if sys.isltv()
                % Overwrite the following parameters with their
                % time-varying counterparts
                inverted_state_matrix = inv(sys.state_mat(current_time));
                minus_bu = (-sys.input_mat(current_time)) * sys.input_space;
                minus_scaled_dist_set = (-sys.dist_mat(current_time)) *...
                    disturbance_set;
            end
            
            if isa(disturbance_set,'Polyhedron') && disturbance_set.isEmptySet
                % No augmentation
                new_target = effective_target_tube(itt+1);
            else
                % Compute a new target set for this iteration that is robust to 
                % the disturbance
                new_target = minus_scaled_dist_set.plus(...
                    effective_target_tube(itt+1));
            end

            % One-step backward reach set
            one_step_backward_reach_set = inverted_state_matrix * ...
                (new_target + minus_bu);

            % Guarantee staying within target_tube by intersection
            effective_target_tube(itt) = intersect(...
                one_step_backward_reach_set, target_tube(itt));
        end
    end
end

function [effective_target_set] = computeViaSupportFn(sys, target_tube,...
    disturbance_set, options)   
% This private function implements the support function-based
% recursion-free implementation of Lagrangian overapproximation of the
% stochastic reach set.
%
% ============================================================================
%
%   This function is part of the Stochastic Reachability Toolbox.
%   License for the use of this function is given in
%        https://github.com/unm-hscl/SReachTools/blob/master/LICENSE
%

    if isempty(options.equi_dir_vecs)
        throwAsCaller(SrtInvalidArgsError(['Expected non-empty ',...
            'equi_dir_vecs. Faulty options structure provided!']));
    end
    % Get size of equi_dir_vecs
    [dir_vecs_dim, n_vertices] = size(options.equi_dir_vecs);

    if dir_vecs_dim ~= (sys.state_dim) || n_vertices < 3
        throwAsCaller(SrtInvalidArgsError(['Expected (sys.state_dim + ',...
            'sys.input_dim)-dimensional collection of column vectors. ',...
            'Faulty options structure provided!']));        
    end
    
    effective_target_set_A = zeros(n_vertices, dir_vecs_dim);
    effective_target_set_b = zeros(n_vertices, 1);
    if options.verbose == 1
        fprintf('Computation of ell: 00000/%5d',n_vertices);
    end
        
    for dir_indx = 1:n_vertices
        if options.verbose == 1
            fprintf('\b\b\b\b\b\b\b\b\b\b\b%5d/%5d',dir_indx, n_vertices);
        elseif options.verbose == 2
            fprintf('\n\nComputation of ell: %5d/%5d\n\n',dir_indx, n_vertices);
        end
        ell = options.equi_dir_vecs(:, dir_indx);
        effective_target_set_A(dir_indx, :)= ell';
        effective_target_set_b(dir_indx) =...
            support(ell, sys, target_tube, disturbance_set, options);
        if options.verbose >= 2 && size(ell,1) <=3
            figure(200);
            hold on;
            title(sprintf('ell: %d/%d',dir_indx, n_vertices));
            p_temp = Polyhedron('H',[ell' effective_target_set_b(dir_indx)]);
            plot(p_temp.intersect(target_tube(1)),'alpha',0);
            %scatter(ell(1),ell(2),300,'rx');
            quiver(0,0,ell(1),ell(2),'rx');
            axis equal;
            drawnow;
        end
    end
    effective_target_set = Polyhedron('H', [effective_target_set_A, ...
        effective_target_set_b]);
    if options.verbose >= 1
        fprintf('\n');
    end
end

function [val] = support(ell, sys, target_tube, dist_set, options)
    time_horizon = length(target_tube) - 1;
    n_lin_input = size(sys.input_space.A,1);
    concat_target_tube_A = target_tube.concat();
    cvx_begin
        if options.verbose >= 2
            cvx_quiet false
        else
            cvx_quiet true
        end
            
        variable slack_var_target(time_horizon + 1, 1);
        variable slack_var_inputdist(time_horizon, 1);
        variable dummy_var(sys.state_dim, time_horizon)
        variable dual_var_target(size(concat_target_tube_A,1), 1);
        variable dual_var_input(n_lin_input, time_horizon);        
        
        minimize (sum(slack_var_target) + sum(slack_var_inputdist))
        
        subject to
            % Dual variables are nonnegative
            dual_var_target >= 0;
            dual_var_input >= 0;
            
            dual_var_start_indx = 1;
            dual_var_end_indx = size(target_tube(1).A,1);
                
            for tube_indx = 1:time_horizon + 1
                % current_time, denoted by k, is t_indx-1 and goes from 0 to N
                current_time = tube_indx - 1;
                inv_sys_now = inv(sys.state_mat(current_time));
                if current_time >= 1
                    inv_sys_prev = inv(sys.state_mat(current_time - 1));                
                end
                %[tube_indx dual_var_start_indx dual_var_end_indx]
                %% Target set at t \in N_{[0, N]}
                % Here, psi_k refers to the dummy variable
                if tube_indx == 1
                    % A_Target_0'*z_Target_0 == l - psi_0
                    (target_tube(1).A)'*dual_var_target(...
                        dual_var_start_indx:dual_var_end_indx) ==...
                        (ell - dummy_var(:,1));                    
                elseif tube_indx < time_horizon + 1
                    % A_Target_k'*z_Target_k==(A_sys_(k-1)^{-T}*psi_{t-1}-psi_k)
                    (target_tube(tube_indx).A)'*dual_var_target(...
                        dual_var_start_indx:dual_var_end_indx) ==...
                            (inv_sys_prev' * dummy_var(:,tube_indx - 1) -...
                                dummy_var(:, tube_indx));
                elseif tube_indx == time_horizon + 1
                    % A_Target_{N}'*z_Target_{N} == A_sys_(N-1)^{-T}*psi_{N-1}
                    % N + 1 is the corresponding tube_indx for k=N
                    (target_tube(time_horizon + 1).A)' *...
                        dual_var_target(...
                            dual_var_start_indx:dual_var_end_indx) ==...
                            (inv_sys_prev' * dummy_var(:,time_horizon));
                end
                
                % b_Target_k'*z_Target_k <= s_Target_k
                (target_tube(tube_indx).b)' * dual_var_target(...
                            dual_var_start_indx:dual_var_end_indx) <=...
                                        slack_var_target(tube_indx);
                % Increment the start counter
                if tube_indx <= time_horizon
                    dual_var_start_indx = dual_var_end_indx + 1;
                    dual_var_end_indx = dual_var_start_indx - 1 + ...
                         size(target_tube(tube_indx+1).A,1);
                end
                
                %% Support function of (-BU) + (-FE) for k from 0 to N-1
                if tube_indx <= time_horizon
                    % Compute F_k E for k from 0 to N-1
                    minus_fe_now = - sys.dist_mat(current_time) * dist_set;

                    % A_u' * z_u_k == -B_k^T A^{-T}_k psi_k
                    (sys.input_space.A)'*dual_var_input(:, tube_indx) ==...
                        - sys.input_mat(current_time)' * inv_sys_now' *...
                            dummy_var(:, tube_indx);
                    
                    % b_u' * z_u_k + minus_fe_now.support(A^{-T}_k psi_k)
                    %                                           <= s_inputdist_k
                    (sys.input_space.b)'*dual_var_input(:, tube_indx) +...
                        minus_fe_now.support(...
                            inv_sys_now'*dummy_var(:, tube_indx))...
                            <= slack_var_inputdist(tube_indx);
                end
            end
    cvx_end
    switch cvx_status
        case {'Solved','Solved/Inaccurate'}
            val = cvx_optval;
        otherwise
            throw(SrtInvalidArgsError('Support function computation failed.'));
    end
end

% Things left to do:
% 1. Switch to polyhedral disturbance set based on the dist_set
% 2. Switch to time-based polytope
% 3. Do the affine transformation via ellipse
%
% % slack_var_inputdist constraint depends on type of dist_set
%                     if isa(scaled_dist_set,'SReachEllipsoid')
%                         % b_u'*z_u_k + sup_ell(A^{-T}_k psi_k) <= s_InputDist_k
%                         (scaled_input_set.b)'*dual_var_input(:, tube_indx) +...
%                             scaled_dist_set.support(inv_sys_now'*...
%                                 dummy_var(:, tube_indx)) <=...
%                                     slack_var_inputdist(tube_indx);
%                     elseif isa(scaled_dist_set,'Polyhedron')
%                     else
%                         throw(SrtInvalidArgsError(sprintf(['Disturbance ',...
%                             '(%s) is not configured as of yet'],...
%                             class(scaled_dist_set))));
%                     end
%%%%%%%%%%%%%%%%%                    
%         if isa(dist_set,'Polyhedron')
%             minus_fe_now = (sys.dist_mat(0) * dist_set);
%             n_lin_dist = size(minus_fe_now.A,1);
%             
%             variable dual_var_dist(n_lin_dist, time_horizon);
%         end
%             dual_var_dist >= 0;            
%             norms(dummy_var, 2) <= 1;
%%%%%%%%%%%%%%%%%                    
%                     % b_u'*z_u_k + b_E' * z_E_k <= s_InputDist_k
%                     (minus_bu_now.b)'*dual_var_input(:, tube_indx) +...
%                         (minus_fe_now.b)'*dual_var_dist(:,tube_indx)... 
%                             <= slack_var_inputdist(tube_indx);
%                     % A_E' * z_E_k == A^{-T}_k psi_k
%                     (minus_fe_now.A)'*dual_var_dist(:, tube_indx) ==...
%                         inv_sys_now'*dummy_var(:, tube_indx);
